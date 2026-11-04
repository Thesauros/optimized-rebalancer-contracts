// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessManager} from "../access/AccessManager.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {ITickAccountant} from "../tick/interfaces/ITickAccountant.sol";

interface IEpochVaultFunds {
    function returnFunds(uint256 assets) external;
}

/**
 * @title ChainAgent
 * @notice Holds Thesauros capital on one chain: idle asset plus shares of one
 *         strategy vault (a `Rebalancer`). Moves capital only along paths fixed
 *         by governance: into/out of that strategy, across Timelock-configured
 *         bridge routes to fixed peer agents, and (on the hub) back to the vault.
 *
 * @dev Every accounting fact is an event of a measured token movement. There is
 *      no status setter: a transfer is in flight from `BridgeOut` on the source
 *      until `BridgeIn` with the same id on the destination. The source cannot
 *      observe completion, so its hard bound on in-flight value is the route
 *      volume bucket (capacity + refill * transit time).
 *      See docs/tick-accounting-design.md §9.
 */
contract ChainAgent is Initializable, ReentrancyGuardUpgradeable, AccessManager {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint8 public constant DOMAIN_ALLOCATE = 0;
    uint8 public constant DOMAIN_BRIDGE_OUT = 1;
    uint8 internal constant DOMAIN_COUNT = 2;

    error InvalidInput();
    error InvalidConfig();
    error DomainPaused(uint8 domain);
    error RouteDisabled();
    error LimitExceeded();
    error InsufficientIdle();
    error SlippageExceeded();
    error UnexpectedTokenAmount();
    error UnknownAdapter();
    error UnknownPeer();
    error AlreadyReceived();
    error UnknownTransfer();
    error SendsHalted();
    error NotHub();
    error StrategyNotEmpty();

    struct Route {
        address adapter;
        uint64 dstChainId;
        address dstAgent;
        uint16 maxFeeBps;
        bool enabled;
        uint128 maxPerTransfer;
        uint128 capacity;
        uint128 refillPerSecond;
        uint128 level;
        uint64 updatedAt;
    }

    struct Sent {
        bytes32 routeId;
        uint64 dstChainId;
        uint64 sentAt;
        uint128 amount;
        uint128 minReceive;
        uint128 writtenDown;
    }

    struct Received {
        uint64 srcChainId;
        uint64 receivedAt;
        uint128 amount;
    }

    event Allocated(address indexed strategy, uint256 assets, uint256 shares);
    event Deallocated(address indexed strategy, uint256 assets, uint256 shares);
    event BridgeOut(
        bytes32 indexed transferId,
        bytes32 indexed rebalanceId,
        bytes32 indexed routeId,
        uint64 dstChainId,
        address dstAgent,
        uint256 amount,
        uint256 minReceive
    );
    event BridgeIn(bytes32 indexed transferId, uint64 indexed srcChainId, address indexed srcAgent, uint256 amount);
    event WrittenDown(bytes32 indexed transferId, uint256 amount, uint256 totalWrittenDown, bytes32 reason);
    event ReturnedToVault(address indexed vault, uint256 assets);
    event RouteAdded(bytes32 indexed routeId, address adapter, uint64 dstChainId, address dstAgent);
    event RouteConfigured(bytes32 indexed routeId, bool enabled, uint16 maxFeeBps, uint128 maxPerTransfer, uint128 capacity, uint128 refillPerSecond);
    event PeerUpdated(uint64 indexed chainId, address indexed agent, bool allowed);
    event AdapterUpdated(address indexed adapter, bool allowed);
    event StrategyUpdated(address indexed strategy);
    event PauseSet(uint8 indexed domain, bool paused, address indexed by);
    event TimelockUpdated(address indexed timelock);

    /// @custom:storage-location erc7201:thesauros.storage.ChainAgent
    struct ChainAgentStorage {
        IERC20 _asset;
        IERC4626 _strategy;
        address _vault;
        ITickAccountant _accountant;
        address _timelock;
        uint256 _paused;
        uint256 _nonce;
        mapping(bytes32 routeId => Route) _routes;
        mapping(uint64 chainId => mapping(address agent => bool)) _peers;
        mapping(address adapter => bool) _adapters;
        mapping(bytes32 transferId => Sent) _sent;
        mapping(bytes32 transferId => Received) _received;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.ChainAgent")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ChainAgentStorageLocation =
        0xa350913476bf4a8b1933612e57508cbb9cd46ba40a6a18a9a187f312701be300;

    function _getStorage() private pure returns (ChainAgentStorage storage $) {
        assembly {
            $.slot := ChainAgentStorageLocation
        }
    }

    modifier onlyTimelock() {
        if (_msgSender() != _getStorage()._timelock) revert Unauthorized();
        _;
    }

    modifier whenNotPaused(uint8 domain) {
        if (paused(domain)) revert DomainPaused(domain);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @param vault_ Hub EpochVault, or address(0) on a spoke.
     * @param accountant_ Hub TickAccountant, or address(0) on a spoke. On the hub
     *        its breakers gate allocations and outbound sends automatically; on
     *        spokes the guardian pauses them.
     */
    function initialize(
        address asset_,
        address admin_,
        address timelock_,
        address strategy_,
        address vault_,
        address accountant_
    ) external initializer {
        if (asset_ == address(0) || admin_ == address(0) || strategy_ == address(0)) {
            revert InvalidConfig();
        }
        if ((vault_ == address(0)) != (accountant_ == address(0))) revert InvalidConfig();
        if (IERC4626(strategy_).asset() != asset_) revert InvalidConfig();

        __ReentrancyGuard_init();
        __AccessManager_init(admin_);
        ChainAgentStorage storage $ = _getStorage();
        $._asset = IERC20(asset_);
        $._strategy = IERC4626(strategy_);
        $._vault = vault_;
        $._accountant = ITickAccountant(accountant_);
        _setTimelock(timelock_);
        emit StrategyUpdated(strategy_);
    }

    /*//////////////////////////////////////////////////////////////
                               STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits idle asset into the configured strategy.
    function allocate(
        uint256 assets
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) whenNotPaused(DOMAIN_ALLOCATE) returns (uint256 shares) {
        ChainAgentStorage storage $ = _getStorage();
        if (address($._accountant) != address(0) && $._accountant.frozen()) revert SendsHalted();
        if (assets == 0 || assets > $._asset.balanceOf(address(this))) revert InsufficientIdle();

        IERC4626 strat = $._strategy;
        $._asset.forceApprove(address(strat), assets);
        shares = strat.deposit(assets, address(this));
        $._asset.forceApprove(address(strat), 0);
        emit Allocated(address(strat), assets, shares);
    }

    /// @notice Withdraws `assets` from the strategy to idle. Never paused.
    function deallocate(uint256 assets) external nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256 shares) {
        ChainAgentStorage storage $ = _getStorage();
        IERC4626 strat = $._strategy;
        uint256 before = $._asset.balanceOf(address(this));
        shares = strat.withdraw(assets, address(this), address(this));
        uint256 received = $._asset.balanceOf(address(this)) - before;
        // Measured amount: the balance delta across the external call IS the
        // accounting fact, and `nonReentrant` plus a non-rebasing asset are what
        // make the pre-call reading safe to compare against.
        // slither-disable-next-line reentrancy-balance
        if (received != assets) revert UnexpectedTokenAmount();
        emit Deallocated(address(strat), received, shares);
    }

    /// @notice Redeems `shares` of the strategy to idle. Never paused.
    /// @dev A redeem releases a variable amount, so the executor states the floor
    ///      it accepts; the received amount is still measured, never assumed.
    function deallocateShares(
        uint256 shares,
        uint256 minAssets
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256 received) {
        ChainAgentStorage storage $ = _getStorage();
        IERC4626 strat = $._strategy;
        uint256 before = $._asset.balanceOf(address(this));
        strat.redeem(shares, address(this), address(this));
        received = $._asset.balanceOf(address(this)) - before;
        // slither-disable-next-line reentrancy-balance
        if (received < minAssets) revert SlippageExceeded();
        emit Deallocated(address(strat), received, shares);
    }

    /*//////////////////////////////////////////////////////////////
                                BRIDGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends idle asset along a fixed route to its peer agent.
     * @dev The executor chooses only the route id, the amount and the minimum
     *      received (bounded below by the route's fee cap). The recipient and the
     *      destination chain come from the route. The debit is measured.
     * @param rebalanceId Free label that groups the legs of one rebalance in events.
     */
    function bridgeOut(
        bytes32 routeId,
        uint256 amount,
        uint256 minReceive,
        bytes32 rebalanceId
    ) external payable nonReentrant onlyRole(EXECUTOR_ROLE) whenNotPaused(DOMAIN_BRIDGE_OUT) returns (bytes32 transferId) {
        ChainAgentStorage storage $ = _getStorage();
        Route storage route = $._routes[routeId];
        if (!route.enabled) revert RouteDisabled();
        // on the hub this folds in the accountant's breakers and refuses a
        // destination that is already above its exposure cap; on a spoke there is
        // no accountant to read and the guardian pauses instead
        if (
            address($._accountant) != address(0) &&
            !$._accountant.chainSendAllowed(route.dstChainId)
        ) {
            revert SendsHalted();
        }
        if (amount == 0 || minReceive > amount) revert InvalidInput();
        if (amount > route.maxPerTransfer) revert LimitExceeded();
        if (minReceive < amount.mulDiv(BPS - route.maxFeeBps, BPS, Math.Rounding.Ceil)) {
            revert LimitExceeded();
        }
        _consume(route, amount);

        IERC20 token = $._asset;
        if (amount > token.balanceOf(address(this))) revert InsufficientIdle();

        transferId = keccak256(abi.encode(block.chainid, address(this), ++$._nonce));
        $._sent[transferId] = Sent({
            routeId: routeId,
            dstChainId: route.dstChainId,
            sentAt: uint64(block.timestamp),
            amount: amount.toUint128(),
            minReceive: minReceive.toUint128(),
            writtenDown: 0
        });

        uint256 before = token.balanceOf(address(this));
        token.forceApprove(route.adapter, amount);
        IBridgeAdapter(route.adapter).send{value: msg.value}(
            transferId,
            amount,
            route.dstChainId,
            route.dstAgent,
            minReceive
        );
        token.forceApprove(route.adapter, 0);
        // slither-disable-next-line reentrancy-balance
        if (before - token.balanceOf(address(this)) != amount) revert UnexpectedTokenAmount();

        emit BridgeOut(transferId, rebalanceId, routeId, route.dstChainId, route.dstAgent, amount, minReceive);
    }

    /**
     * @notice Delivers an inbound bridge message. Permissionless: anyone may relay
     *         a valid message; the agent measures what actually arrived.
     */
    function receiveBridge(
        address adapter,
        bytes calldata payload
    ) external nonReentrant returns (bytes32 transferId, uint256 amount) {
        ChainAgentStorage storage $ = _getStorage();
        if (!$._adapters[adapter]) revert UnknownAdapter();

        IERC20 token = $._asset;
        uint256 before = token.balanceOf(address(this));
        uint64 srcChainId;
        address srcAgent;
        (transferId, srcChainId, srcAgent) = IBridgeAdapter(adapter).finalize(payload);
        amount = token.balanceOf(address(this)) - before;

        if (!$._peers[srcChainId][srcAgent]) revert UnknownPeer();
        if ($._received[transferId].receivedAt != 0) revert AlreadyReceived();
        // slither-disable-next-line reentrancy-balance
        if (amount == 0) revert UnexpectedTokenAmount();

        $._received[transferId] = Received({
            srcChainId: srcChainId,
            receivedAt: uint64(block.timestamp),
            amount: amount.toUint128()
        });
        emit BridgeIn(transferId, srcChainId, srcAgent, amount);
    }

    /**
     * @notice Governance write-down of an unresolved outbound transfer.
     * @dev Reduces the transfer's value in snapshots; a later receipt on the
     *      destination books the recovery under the same id.
     */
    function writeDown(bytes32 transferId, uint256 amount, bytes32 reason) external onlyRole(ADMIN_ROLE) {
        Sent storage s = _getStorage()._sent[transferId];
        if (s.sentAt == 0) revert UnknownTransfer();
        if (amount == 0 || reason == bytes32(0) || s.writtenDown + amount > s.amount) {
            revert InvalidInput();
        }
        s.writtenDown += amount.toUint128();
        emit WrittenDown(transferId, amount, s.writtenDown, reason);
    }

    /// @notice Hub only: returns idle asset to the EpochVault. Never paused.
    function returnToVault(uint256 assets) external nonReentrant onlyRole(EXECUTOR_ROLE) {
        ChainAgentStorage storage $ = _getStorage();
        address vault_ = $._vault;
        if (vault_ == address(0)) revert NotHub();
        $._asset.forceApprove(vault_, assets);
        IEpochVaultFunds(vault_).returnFunds(assets);
        $._asset.forceApprove(vault_, 0);
        emit ReturnedToVault(vault_, assets);
    }

    function _consume(Route storage route, uint256 amount) internal {
        uint256 level = uint256(route.level) + (block.timestamp - route.updatedAt) * route.refillPerSecond;
        if (level > route.capacity) level = route.capacity;
        if (amount > level) revert LimitExceeded();
        route.level = uint128(level - amount);
        route.updatedAt = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE AND GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function pause(uint8 domain) external {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(ADMIN_ROLE, _msgSender())) {
            revert Unauthorized();
        }
        if (domain >= DOMAIN_COUNT) revert InvalidInput();
        _getStorage()._paused |= (1 << domain);
        emit PauseSet(domain, true, _msgSender());
    }

    function unpause(uint8 domain) external onlyRole(ADMIN_ROLE) {
        if (domain >= DOMAIN_COUNT) revert InvalidInput();
        _getStorage()._paused &= ~(uint256(1) << domain);
        emit PauseSet(domain, false, _msgSender());
    }

    function paused(uint8 domain) public view returns (bool) {
        return _getStorage()._paused & (1 << domain) != 0;
    }

    /// @notice Adds a route. Endpoints are permanent; a new endpoint needs a new id.
    function addRoute(
        bytes32 routeId,
        address adapter,
        uint64 dstChainId,
        address dstAgent,
        uint16 maxFeeBps,
        uint128 maxPerTransfer,
        uint128 capacity,
        uint128 refillPerSecond
    ) external onlyTimelock {
        ChainAgentStorage storage $ = _getStorage();
        if (
            routeId == bytes32(0) ||
            $._routes[routeId].adapter != address(0) ||
            adapter.code.length == 0 ||
            IBridgeAdapter(adapter).asset() != address($._asset) ||
            dstChainId == 0 ||
            dstChainId == block.chainid ||
            dstAgent == address(0) ||
            maxFeeBps >= BPS
        ) revert InvalidConfig();
        $._routes[routeId] = Route({
            adapter: adapter,
            dstChainId: dstChainId,
            dstAgent: dstAgent,
            maxFeeBps: maxFeeBps,
            enabled: true,
            maxPerTransfer: maxPerTransfer,
            capacity: capacity,
            refillPerSecond: refillPerSecond,
            level: capacity,
            updatedAt: uint64(block.timestamp)
        });
        emit RouteAdded(routeId, adapter, dstChainId, dstAgent);
        emit RouteConfigured(routeId, true, maxFeeBps, maxPerTransfer, capacity, refillPerSecond);
    }

    function configureRoute(
        bytes32 routeId,
        bool enabled,
        uint16 maxFeeBps,
        uint128 maxPerTransfer,
        uint128 capacity,
        uint128 refillPerSecond
    ) external onlyTimelock {
        Route storage route = _getStorage()._routes[routeId];
        if (route.adapter == address(0) || maxFeeBps >= BPS) revert InvalidConfig();
        route.enabled = enabled;
        route.maxFeeBps = maxFeeBps;
        route.maxPerTransfer = maxPerTransfer;
        route.capacity = capacity;
        route.refillPerSecond = refillPerSecond;
        if (route.level > capacity) route.level = capacity;
        emit RouteConfigured(routeId, enabled, maxFeeBps, maxPerTransfer, capacity, refillPerSecond);
    }

    /// @notice Disabling a route is an emergency action and needs no delay.
    function disableRoute(bytes32 routeId) external {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(ADMIN_ROLE, _msgSender())) {
            revert Unauthorized();
        }
        Route storage route = _getStorage()._routes[routeId];
        route.enabled = false;
        emit RouteConfigured(routeId, false, route.maxFeeBps, route.maxPerTransfer, route.capacity, route.refillPerSecond);
    }

    function setPeer(uint64 chainId, address agent, bool allowed) external onlyTimelock {
        if (chainId == 0 || agent == address(0)) revert InvalidConfig();
        _getStorage()._peers[chainId][agent] = allowed;
        emit PeerUpdated(chainId, agent, allowed);
    }

    function setAdapter(address adapter, bool allowed) external onlyTimelock {
        if (adapter.code.length == 0) revert InvalidConfig();
        _getStorage()._adapters[adapter] = allowed;
        emit AdapterUpdated(adapter, allowed);
    }

    /// @notice Replaces the strategy; only while no strategy shares are held.
    function setStrategy(address strategy_) external onlyTimelock {
        ChainAgentStorage storage $ = _getStorage();
        if (IERC20(address($._strategy)).balanceOf(address(this)) != 0) revert StrategyNotEmpty();
        if (IERC4626(strategy_).asset() != address($._asset)) revert InvalidConfig();
        $._strategy = IERC4626(strategy_);
        emit StrategyUpdated(strategy_);
    }

    function setTimelock(address timelock_) external onlyTimelock {
        _setTimelock(timelock_);
    }

    function _setTimelock(address timelock_) internal {
        if (timelock_ == address(0)) revert InvalidConfig();
        _getStorage()._timelock = timelock_;
        emit TimelockUpdated(timelock_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(_getStorage()._asset);
    }

    function strategy() external view returns (address) {
        return address(_getStorage()._strategy);
    }

    function vault() external view returns (address) {
        return _getStorage()._vault;
    }

    function idle() external view returns (uint256) {
        return _getStorage()._asset.balanceOf(address(this));
    }

    function strategyShares() external view returns (uint256) {
        return IERC20(address(_getStorage()._strategy)).balanceOf(address(this));
    }

    function getRoute(bytes32 routeId) external view returns (Route memory) {
        return _getStorage()._routes[routeId];
    }

    function getSent(bytes32 transferId) external view returns (Sent memory) {
        return _getStorage()._sent[transferId];
    }

    function getReceived(bytes32 transferId) external view returns (Received memory) {
        return _getStorage()._received[transferId];
    }

    function isPeer(uint64 chainId, address agent) external view returns (bool) {
        return _getStorage()._peers[chainId][agent];
    }

    function isAdapter(address adapter) external view returns (bool) {
        return _getStorage()._adapters[adapter];
    }

    function nonce() external view returns (uint256) {
        return _getStorage()._nonce;
    }

    function getTimelock() external view returns (address) {
        return _getStorage()._timelock;
    }
}
