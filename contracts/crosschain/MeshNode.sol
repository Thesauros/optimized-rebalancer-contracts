// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {IMeshNode} from "./interfaces/IMeshNode.sol";
import {IMeshBridgeAdapter} from "./interfaces/IMeshBridgeAdapter.sol";

/// @notice Source-side principal ledger for an asynchronous bridge/custody cycle.
/// @dev Non-upgradeable. No yield reports, token sweeping, arbitrary execution or
/// vault transferFrom. Route adapters and registered vault code are governance trust.
contract MeshNode is IMeshNode, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidAmount();
    error Paused();
    error InsufficientLiquidity();
    error LimitExceeded();
    error InvalidTransfer();
    error InvalidPeer();
    error UnexpectedTokenAmount();

    struct VaultConfig {
        bool depositsEnabled;
        uint16 minLocalBps;
        uint16 maxRemoteBps;
    }

    struct Route {
        address adapter;
        uint256 chainId;
        bytes32 peer;
        uint256 maxInFlight;
        uint256 inFlight;
        uint16 maxFeeBps;
        bool enabled;
    }

    enum Status {
        None,
        Pending,
        Settled
    }

    struct Transfer {
        address vault;
        bytes32 routeId;
        uint256 principal;
        uint256 bookValue;
        uint256 sentAt;
        Status status;
    }

    address public immutable asset;
    address public immutable governance;
    address public executor;
    address public guardian;
    bool public paused;
    uint256 public nonce;
    uint256 public totalLocalAssets;
    uint256 public totalRemoteAssets;

    mapping(address => VaultConfig) public vaults;
    mapping(address => uint256) public localAssets;
    mapping(address => uint256) public remoteAssets;
    /// @notice Nominal unsettled exposure, including principal already written down.
    mapping(address => uint256) public pendingPrincipal;
    mapping(bytes32 => Route) public routes;
    mapping(bytes32 => Transfer) public transfers;

    event VaultConfigured(address indexed vault, bool enabled, uint16 minLocalBps, uint16 maxRemoteBps);
    event RolesUpdated(address indexed executor, address indexed guardian);
    event PauseUpdated(bool paused);
    event RouteAdded(bytes32 indexed routeId, address indexed adapter, uint256 chainId, bytes32 peer);
    event RouteConfigured(bytes32 indexed routeId, bool enabled, uint256 maxInFlight, uint16 maxFeeBps);
    event Deposited(address indexed vault, uint256 amount);
    event Withdrawn(address indexed vault, uint256 amount);
    event BridgeOut(
        bytes32 indexed transferId, address indexed vault, bytes32 indexed routeId, uint256 sent, uint256 principal
    );
    event Returned(bytes32 indexed transferId, address indexed vault, uint256 bookValue, uint256 received);
    event WrittenDown(bytes32 indexed transferId, uint256 loss, bytes32 reason);

    constructor(address asset_, address governance_, address executor_, address guardian_) {
        if (asset_.code.length == 0 || governance_.code.length == 0) revert InvalidConfiguration();
        asset = asset_;
        governance = governance_;
        _setRoles(executor_, guardian_);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    function setRoles(address executor_, address guardian_) external onlyGovernance nonReentrant {
        _setRoles(executor_, guardian_);
    }

    function _setRoles(address executor_, address guardian_) internal {
        if (executor_ == address(0) || guardian_ == address(0)) revert InvalidConfiguration();
        executor = executor_;
        guardian = guardian_;
        emit RolesUpdated(executor_, guardian_);
    }

    function setPaused(bool value) external nonReentrant {
        if (msg.sender != governance && (msg.sender != guardian || !value)) revert Unauthorized();
        paused = value;
        emit PauseUpdated(value);
    }

    function configureVault(address vault, bool enabled, uint16 minLocalBps, uint16 maxRemoteBps)
        external
        onlyGovernance
        nonReentrant
    {
        if (vault.code.length == 0 || minLocalBps > BPS || maxRemoteBps > BPS) revert InvalidConfiguration();
        if (IRebalancer(vault).asset() != asset) revert InvalidConfiguration();
        vaults[vault] = VaultConfig(enabled, minLocalBps, maxRemoteBps);
        emit VaultConfigured(vault, enabled, minLocalBps, maxRemoteBps);
    }

    /// @notice Endpoints are permanent. Add a new route ID for a new adapter/peer.
    function addRoute(
        bytes32 routeId,
        address adapter,
        uint256 chainId,
        bytes32 peer,
        uint256 maxInFlight,
        uint16 maxFeeBps
    ) external onlyGovernance nonReentrant {
        if (
            routeId == bytes32(0) || routes[routeId].adapter != address(0) || adapter.code.length == 0 || chainId == 0
                || chainId == block.chainid || peer == bytes32(0) || maxInFlight == 0 || maxFeeBps >= BPS
        ) revert InvalidConfiguration();
        routes[routeId] = Route(adapter, chainId, peer, maxInFlight, 0, maxFeeBps, true);
        emit RouteAdded(routeId, adapter, chainId, peer);
        emit RouteConfigured(routeId, true, maxInFlight, maxFeeBps);
    }

    function configureRoute(bytes32 routeId, bool enabled, uint256 maxInFlight, uint16 maxFeeBps)
        external
        onlyGovernance
        nonReentrant
    {
        Route storage route = routes[routeId];
        if (route.adapter == address(0) || maxInFlight == 0 || maxFeeBps >= BPS) revert InvalidConfiguration();
        route.enabled = enabled;
        route.maxInFlight = maxInFlight;
        route.maxFeeBps = maxFeeBps;
        emit RouteConfigured(routeId, enabled, maxInFlight, maxFeeBps);
    }

    function balanceOf(address vault) external view returns (uint256) {
        return localAssets[vault] + remoteAssets[vault];
    }

    function totalAssets() external view returns (uint256) {
        return totalLocalAssets + totalRemoteAssets;
    }

    /// @dev The registered vault's delegatecalled provider transfers then credits in
    /// one transaction. Ignore unsolicited excess tokens; never reprice claims with them.
    function depositFromVault(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (!vaults[msg.sender].depositsEnabled) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (IERC20(asset).balanceOf(address(this)) < totalLocalAssets + amount) revert UnexpectedTokenAmount();
        localAssets[msg.sender] += amount;
        totalLocalAssets += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Exits remain available even if new deposits/sends are disabled.
    function withdrawToVault(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > localAssets[msg.sender]) revert InsufficientLiquidity();
        localAssets[msg.sender] -= amount;
        totalLocalAssets -= amount;
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(msg.sender);
        token.safeTransfer(msg.sender, amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(msg.sender);
        if (
            afterBalance > beforeBalance || beforeBalance - afterBalance != amount || afterRecipient < beforeRecipient
                || afterRecipient - beforeRecipient != amount
        ) {
            revert UnexpectedTokenAmount();
        }
        emit Withdrawn(msg.sender, amount);
    }

    function bridgeOut(address vault, bytes32 routeId, uint256 amount, uint256 minAmountOut)
        external
        payable
        nonReentrant
        returns (bytes32 transferId)
    {
        if (msg.sender != executor) revert Unauthorized();
        if (paused) revert Paused();
        Route storage route = routes[routeId];
        VaultConfig memory config = vaults[vault];
        if (!config.depositsEnabled || !route.enabled) revert InvalidConfiguration();
        if (amount == 0 || minAmountOut == 0 || minAmountOut > amount) revert InvalidAmount();
        if (amount > localAssets[vault]) revert InsufficientLiquidity();
        uint256 minimum = Math.mulDiv(amount, BPS - route.maxFeeBps, BPS, Math.Rounding.Ceil);
        if (minAmountOut < minimum) revert LimitExceeded();

        localAssets[vault] -= amount;
        totalLocalAssets -= amount;
        remoteAssets[vault] += amount;
        totalRemoteAssets += amount;
        transferId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        transfers[transferId] = Transfer(vault, routeId, amount, amount, block.timestamp, Status.Pending);

        uint256 credited = _executeBridgeSend(route, transferId, amount, minAmountOut);
        _postBridgeAccount(vault, routeId, route, config, transferId, amount, credited);
    }

    function _executeBridgeSend(Route storage route, bytes32 transferId, uint256 amount, uint256 minAmountOut)
        internal
        returns (uint256 credited)
    {
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.forceApprove(route.adapter, amount);
        credited = IMeshBridgeAdapter(route.adapter).send{value: msg.value}(
            transferId, asset, amount, route.chainId, route.peer, minAmountOut
        );
        token.forceApprove(route.adapter, 0);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert UnexpectedTokenAmount();
        if (credited < minAmountOut || credited > amount) revert UnexpectedTokenAmount();
    }

    function _postBridgeAccount(
        address vault,
        bytes32 routeId,
        Route storage route,
        VaultConfig memory config,
        bytes32 transferId,
        uint256 amount,
        uint256 credited
    ) internal {
        uint256 fee = amount - credited;
        remoteAssets[vault] -= fee;
        totalRemoteAssets -= fee;
        transfers[transferId].principal = credited;
        transfers[transferId].bookValue = credited;
        route.inFlight += credited;
        pendingPrincipal[vault] += credited;
        uint256 nav = localAssets[vault] + remoteAssets[vault];
        if (
            route.inFlight > route.maxInFlight
                || localAssets[vault] < Math.mulDiv(nav, config.minLocalBps, BPS, Math.Rounding.Ceil)
                || pendingPrincipal[vault] > Math.mulDiv(nav, config.maxRemoteBps, BPS)
        ) revert LimitExceeded();
        emit BridgeOut(transferId, vault, routeId, amount, credited);
    }

    function receiveReturn(bytes32 transferId, uint256 sourceChainId, bytes32 sourcePeer, uint256 amount)
        external
        nonReentrant
    {
        Transfer storage transfer = transfers[transferId];
        if (transfer.status != Status.Pending) revert InvalidTransfer();
        Route storage route = routes[transfer.routeId];
        if (msg.sender != route.adapter) revert Unauthorized();
        if (sourceChainId != route.chainId || sourcePeer != route.peer) revert InvalidPeer();
        // Yield must not be credited as an abrupt principal gain in this milestone.
        if (amount > transfer.principal) revert InvalidAmount();
        transfer.status = Status.Settled;
        route.inFlight -= transfer.principal;
        pendingPrincipal[transfer.vault] -= transfer.principal;
        uint256 bookValue = transfer.bookValue;
        transfer.bookValue = 0;
        remoteAssets[transfer.vault] -= bookValue;
        totalRemoteAssets -= bookValue;
        localAssets[transfer.vault] += amount;
        totalLocalAssets += amount;

        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        if (amount != 0) token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnexpectedTokenAmount();
        emit Returned(transferId, transfer.vault, bookValue, amount);
    }

    function writeDown(bytes32 transferId, uint256 loss, bytes32 reason) external onlyGovernance nonReentrant {
        Transfer storage transfer = transfers[transferId];
        if (transfer.status != Status.Pending) revert InvalidTransfer();
        if (loss == 0 || loss > transfer.bookValue || reason == bytes32(0)) revert InvalidAmount();
        transfer.bookValue -= loss;
        remoteAssets[transfer.vault] -= loss;
        totalRemoteAssets -= loss;
        // Keep nominal inFlight exposure until authenticated final settlement.
        emit WrittenDown(transferId, loss, reason);
    }
}
