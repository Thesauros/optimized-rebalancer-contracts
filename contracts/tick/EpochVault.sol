// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20PermitUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessManager} from "../access/AccessManager.sol";
import {ITickAccountant} from "./interfaces/ITickAccountant.sol";
import {IEpochVault} from "./interfaces/IEpochVault.sol";
import {IEpochVaultAccounting} from "./interfaces/IEpochVaultAccounting.sol";
import {EpochVaultStorage} from "./EpochVaultStorage.sol";
import {EpochVaultLogic} from "./EpochVaultLogic.sol";

/**
 * @title EpochVault
 * @notice Hub share token. Deposits and redemptions are requested, batched into
 *         epochs and cleared at forward prices from a Tick observed after the
 *         epoch cutoff (docs/tick-accounting-design.md §5, §8):
 *           - deposits mint at the clearing Tick's OFFER rate;
 *           - redemptions pay min(bid at epoch open, bid at the clearing Tick);
 *           - a capped instant exit pays the latest bid minus a fee.
 *
 * @dev This contract holds the share token, roles, pause domains and every share
 *      mint/burn/transfer. Epoch, clearing, funding, limits, buffer and
 *      checkpoint logic lives in the linked `EpochVaultLogic` library, which runs
 *      under delegatecall on the same ERC-7201 layout (`EpochVaultStorage`).
 *
 *      Accounting fields move only on measured token movements or clearing
 *      arithmetic. Every change to cash, pending deposits, liabilities or supply
 *      writes a per-block checkpoint the TickAccountant binds snapshots to.
 *      Solvency identity: cash >= pendingDeposits + reserved.
 */
contract EpochVault is
    ERC20PermitUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessManager,
    IEpochVault,
    IEpochVaultAccounting
{
    using EpochVaultLogic for EpochVaultStorage.Layout;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint8 public constant DOMAIN_DEPOSIT_REQUEST = 0;
    uint8 public constant DOMAIN_REDEEM_REQUEST = 1;
    uint8 public constant DOMAIN_DEPOSIT_CLEARING = 2;
    uint8 public constant DOMAIN_REDEEM_CLEARING = 3;
    uint8 public constant DOMAIN_INSTANT_EXIT = 4;
    uint8 public constant DOMAIN_ALLOCATE = 5;
    uint8 internal constant DOMAIN_COUNT = 6;

    modifier onlyTimelock() {
        if (_msgSender() != EpochVaultStorage.layout().timelock) revert Unauthorized();
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
     * @notice Initializes the vault and opens epoch 1.
     * @dev Pulls `seedAssets_` from the caller and mints the same number of shares
     *      to the vault itself (dead shares, 1:1 with Tick 0) to rule out
     *      first-depositor inflation.
     */
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address timelock_,
        address accountant_,
        uint256 seedAssets_,
        EpochConfig memory epochConfig_,
        Limits memory limits_
    ) external initializer {
        if (asset_ == address(0) || admin_ == address(0) || accountant_ == address(0) || seedAssets_ == 0) {
            revert InvalidConfig();
        }
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ReentrancyGuard_init();
        __AccessManager_init(admin_);

        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        $.asset = IERC20Metadata(asset_);
        $.decimals = IERC20Metadata(asset_).decimals();
        $.accountant = ITickAccountant(accountant_);
        _setTimelock(timelock_);
        $.setEpochConfig(epochConfig_);
        $.setLimits(limits_);
        $.instantLevel = limits_.dailyInstantLimit;
        $.instantUpdatedAt = uint64(block.timestamp);
        $.nextRequestId = 1;

        $.pullExact(_msgSender(), seedAssets_);
        $.cash = seedAssets_;
        _mint(address(this), seedAssets_);

        $.nextDepositClear = 1;
        $.nextRedeemClear = 1;
        $.nextFund = 1;
        $.openEpoch(1);
        $.checkpoint(totalSupply());
    }

    function decimals() public view override returns (uint8) {
        return EpochVaultStorage.layout().decimals;
    }

    function totalSupply()
        public
        view
        override(ERC20Upgradeable, IEpochVaultAccounting)
        returns (uint256)
    {
        return super.totalSupply();
    }

    /*//////////////////////////////////////////////////////////////
                               REQUESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Queues `assets` for the current epoch. Shares are minted at the
     *         clearing Tick's offer rate and claimed afterwards.
     */
    function requestDeposit(
        uint256 assets,
        address receiver
    ) external nonReentrant whenNotPaused(DOMAIN_DEPOSIT_REQUEST) returns (uint256 requestId) {
        return EpochVaultStorage.layout().requestDeposit(_msgSender(), receiver, assets, totalSupply());
    }

    /**
     * @notice Moves `shares` into escrow for the current epoch. They keep
     *         bearing losses until clearing and stop earning at epoch open.
     */
    function requestRedeem(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant whenNotPaused(DOMAIN_REDEEM_REQUEST) returns (uint256 requestId) {
        if (shares == 0 || receiver == address(0) || owner == address(0)) {
            revert InvalidInput();
        }
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }
        _transfer(owner, address(this), shares);
        return EpochVaultStorage.layout().recordRedeem(owner, receiver, shares);
    }

    /// @notice Cancels a request while its epoch is still open.
    function cancel(uint256 requestId) external nonReentrant {
        (address owner, uint256 sharesToReturn) = EpochVaultStorage.layout().cancel(
            _msgSender(),
            requestId,
            totalSupply()
        );
        if (sharesToReturn != 0) {
            _transfer(address(this), owner, sharesToReturn);
        }
    }

    /**
     * @notice Delivers a cleared deposit's shares or a funded redemption's
     *         assets to the recorded receiver. Callable by anyone.
     */
    function claim(uint256 requestId) external nonReentrant returns (uint256 amountOut) {
        address receiver;
        bool isDeposit;
        (receiver, amountOut, isDeposit) = EpochVaultStorage.layout().claim(requestId, totalSupply());
        if (isDeposit) {
            _transfer(address(this), receiver, amountOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EPOCH LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Closes the current epoch (the cutoff) and opens the next one.
     * @dev Permissionless once (elapsed >= minDuration and at least minTicks
     *      accepted Ticks since open) or elapsed >= maxDuration.
     */
    function closeEpoch() external nonReentrant {
        EpochVaultStorage.layout().closeEpoch();
    }

    /**
     * @notice Clears the oldest closed epoch's deposits at the offer rate of the
     *         latest accepted Tick, which must have been observed after cutoff.
     * @dev Refuses Ticks flagged for a large down-move or overdue in-flight
     *      assets: a wrongly low rate would gift shares to depositors.
     */
    function clearDeposits() external nonReentrant whenNotPaused(DOMAIN_DEPOSIT_CLEARING) {
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        uint256 minted = $.clearDeposits();
        if (minted != 0) _mint(address(this), minted);
        $.checkpoint(totalSupply());
        $.fund();
    }

    /**
     * @notice Clears the oldest closed epoch's redemptions at
     *         min(bid at epoch open, bid at the latest accepted Tick) and burns
     *         the escrowed shares. The owed assets become a liability, paid once
     *         the epoch is funded.
     */
    function clearRedeems() external nonReentrant whenNotPaused(DOMAIN_REDEEM_CLEARING) {
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        uint256 shares = $.clearRedeems();
        if (shares != 0) _burn(address(this), shares);
        $.checkpoint(totalSupply());
        $.fund();
    }

    /// @notice Reserves free cash for cleared redemptions, strictly FIFO by epoch.
    function fund() external nonReentrant {
        EpochVaultStorage.layout().fund();
    }

    /*//////////////////////////////////////////////////////////////
                              INSTANT EXIT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeems immediately from the buffer at the latest bid minus the
     *         instant fee. Backward-priced, so it is capped per call and per day
     *         and requires a fresh, unfrozen Tick.
     */
    function instantRedeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 minAssets
    ) external nonReentrant whenNotPaused(DOMAIN_INSTANT_EXIT) returns (uint256 assets) {
        if (shares == 0 || receiver == address(0) || owner == address(0)) {
            revert InvalidInput();
        }
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }
        _burn(owner, shares);
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        uint64 tickId;
        (tickId, assets) = $.instantRedeem(shares, receiver, minAssets);
        $.checkpoint(totalSupply());
        emit InstantRedeemed(owner, receiver, tickId, shares, assets);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY AND THE HUB AGENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends free cash above the buffer to the hub ChainAgent.
    function pushToAgent(
        uint256 assets
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) whenNotPaused(DOMAIN_ALLOCATE) {
        EpochVaultStorage.layout().pushToAgent(assets, totalSupply());
    }

    /// @notice Pulls `assets` back from the hub ChainAgent. Always allowed.
    function returnFunds(uint256 assets) external nonReentrant {
        EpochVaultStorage.layout().returnFunds(_msgSender(), assets, totalSupply());
    }

    /// @inheritdoc IEpochVaultAccounting
    function mintFeeShares(address to, uint256 shares) external {
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        if (_msgSender() != address($.accountant)) revert NotAccountant();
        _mint(to, shares);
        $.checkpoint(totalSupply());
        emit FeeSharesMinted(to, shares);
    }

    /// @notice max(minimumBuffer, minBufferRatio * latest accepted bid NAV).
    function minimumBuffer() external view returns (uint256) {
        return EpochVaultStorage.layout().minimumBuffer();
    }

    /*//////////////////////////////////////////////////////////////
                         PAUSE AND GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function pause(uint8 domain) external {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(ADMIN_ROLE, _msgSender())) {
            revert Unauthorized();
        }
        if (domain >= DOMAIN_COUNT) revert InvalidInput();
        EpochVaultStorage.layout().paused |= (1 << domain);
        emit PauseSet(domain, true, _msgSender());
    }

    function unpause(uint8 domain) external onlyRole(ADMIN_ROLE) {
        if (domain >= DOMAIN_COUNT) revert InvalidInput();
        EpochVaultStorage.layout().paused &= ~(uint256(1) << domain);
        emit PauseSet(domain, false, _msgSender());
    }

    function paused(uint8 domain) public view returns (bool) {
        return EpochVaultStorage.layout().paused & (1 << domain) != 0;
    }

    function setEpochConfig(EpochConfig calldata c) external onlyTimelock {
        EpochVaultStorage.layout().setEpochConfig(c);
    }

    function setLimits(Limits calldata l) external onlyTimelock {
        EpochVaultStorage.layout().setLimits(l);
    }

    function setHubAgent(address agent) external onlyTimelock {
        if (agent == address(0)) revert InvalidConfig();
        EpochVaultStorage.layout().hubAgent = agent;
        emit HubAgentUpdated(agent);
    }

    function setTimelock(address timelock_) external onlyTimelock {
        _setTimelock(timelock_);
    }

    function _setTimelock(address timelock_) internal {
        if (timelock_ == address(0)) revert InvalidConfig();
        EpochVaultStorage.layout().timelock = timelock_;
        emit TimelockUpdated(timelock_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(EpochVaultStorage.layout().asset);
    }

    function accountant() external view returns (address) {
        return address(EpochVaultStorage.layout().accountant);
    }

    function hubAgent() external view returns (address) {
        return EpochVaultStorage.layout().hubAgent;
    }

    function checkpointCount() external view returns (uint256) {
        return EpochVaultStorage.layout().checkpoints.length;
    }

    function checkpointAt(uint256 index) external view returns (Checkpoint memory) {
        return EpochVaultStorage.layout().checkpoints[index];
    }

    function currentEpoch() external view returns (uint64) {
        return EpochVaultStorage.layout().currentEpoch;
    }

    function getEpoch(uint64 epochId) external view returns (Epoch memory) {
        return EpochVaultStorage.layout().epochs[epochId];
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return EpochVaultStorage.layout().requests[requestId];
    }

    function cursors() external view returns (uint64 nextDepositClear, uint64 nextRedeemClear, uint64 nextFund) {
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        return ($.nextDepositClear, $.nextRedeemClear, $.nextFund);
    }

    /// @notice The named accounting buckets, for dashboards and snapshot builders.
    function accounting()
        external
        view
        returns (
            uint256 cash,
            uint256 pendingDeposits,
            uint256 liabilities,
            uint256 reserved,
            uint256 escrowRedeemShares,
            uint256 unclaimedDepositShares
        )
    {
        EpochVaultStorage.Layout storage $ = EpochVaultStorage.layout();
        return ($.cash, $.pendingDeposits, $.liabilities, $.reserved, $.escrowRedeemShares, $.unclaimedDepositShares);
    }

    function freeCash() external view returns (uint256) {
        return EpochVaultStorage.layout().freeCash();
    }

    function epochConfig() external view returns (EpochConfig memory) {
        return EpochVaultStorage.layout().epochConfig;
    }

    function limits() external view returns (Limits memory) {
        return EpochVaultStorage.layout().limits;
    }

    function getTimelock() external view returns (address) {
        return EpochVaultStorage.layout().timelock;
    }
}
