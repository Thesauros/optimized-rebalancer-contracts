// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20PermitUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessManager} from "../access/AccessManager.sol";
import {ITickAccountant} from "./interfaces/ITickAccountant.sol";
import {IEpochVault} from "./interfaces/IEpochVault.sol";
import {IEpochVaultAccounting} from "./interfaces/IEpochVaultAccounting.sol";

/**
 * @title EpochVault
 * @notice Hub share token. Deposits and redemptions are requested, batched into
 *         epochs and cleared at forward prices from a Tick observed after the
 *         epoch cutoff (docs/tick-accounting-design.md §5, §8):
 *           - deposits mint at the clearing Tick's OFFER rate;
 *           - redemptions pay min(bid at epoch open, bid at the clearing Tick);
 *           - a capped instant exit pays the latest bid minus a fee.
 *
 * @dev Accounting fields are moved only by measured token movements or by
 *      clearing arithmetic, never by status flags. Every change to cash, pending
 *      deposits, liabilities or supply writes a per-block checkpoint that the
 *      TickAccountant binds snapshots to.
 *
 *      Solvency identity: cash >= pendingDeposits + reserved, and
 *      liabilities - reserved is the owed-but-unfunded amount.
 */
contract EpochVault is
    ERC20PermitUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessManager,
    IEpochVault,
    IEpochVaultAccounting
{
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20Metadata;

    uint256 internal constant WAD = 1e18;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint8 public constant DOMAIN_DEPOSIT_REQUEST = 0;
    uint8 public constant DOMAIN_REDEEM_REQUEST = 1;
    uint8 public constant DOMAIN_DEPOSIT_CLEARING = 2;
    uint8 public constant DOMAIN_REDEEM_CLEARING = 3;
    uint8 public constant DOMAIN_INSTANT_EXIT = 4;
    uint8 public constant DOMAIN_ALLOCATE = 5;
    uint8 internal constant DOMAIN_COUNT = 6;

    /// @dev Tick flags that block deposit clearing (mirrors TickAccountant).
    uint8 internal constant DEPOSIT_BLOCKING_FLAGS = (1 << 0) | (1 << 1);

    /// @dev Upper bound on epochs funded per call, to keep gas bounded.
    uint256 internal constant MAX_FUND_ITERATIONS = 16;

    /// @custom:storage-location erc7201:thesauros.storage.EpochVault
    struct EpochVaultStorage {
        IERC20Metadata _asset;
        uint8 _decimals;
        ITickAccountant _accountant;
        address _hubAgent;
        address _timelock;
        uint256 _paused;
        // accounting
        uint256 _cash;
        uint256 _pendingDeposits;
        uint256 _liabilities;
        uint256 _reserved;
        uint256 _escrowRedeemShares;
        uint256 _unclaimedDepositShares;
        Checkpoint[] _checkpoints;
        // epochs
        uint64 _currentEpoch;
        uint64 _nextDepositClear;
        uint64 _nextRedeemClear;
        uint64 _nextFund;
        EpochConfig _epochConfig;
        mapping(uint64 epoch => Epoch) _epochs;
        // requests
        uint256 _nextRequestId;
        mapping(uint256 requestId => Request) _requests;
        // limits
        Limits _limits;
        uint128 _instantLevel;
        uint64 _instantUpdatedAt;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.EpochVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EpochVaultStorageLocation =
        0x7b80b62495198692ae2748b2cdafbaec6bff4d8db0d1e8fb8ff543cac4ce2f00;

    function _getStorage() private pure returns (EpochVaultStorage storage $) {
        assembly {
            $.slot := EpochVaultStorageLocation
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

        EpochVaultStorage storage $ = _getStorage();
        $._asset = IERC20Metadata(asset_);
        $._decimals = IERC20Metadata(asset_).decimals();
        $._accountant = ITickAccountant(accountant_);
        _setTimelock(timelock_);
        _setEpochConfig(epochConfig_);
        _setLimits(limits_);
        $._instantLevel = limits_.dailyInstantLimit;
        $._instantUpdatedAt = uint64(block.timestamp);
        $._nextRequestId = 1;

        _pullExact(_msgSender(), seedAssets_);
        $._cash = seedAssets_;
        _mint(address(this), seedAssets_);

        $._nextDepositClear = 1;
        $._nextRedeemClear = 1;
        $._nextFund = 1;
        _openEpoch(1);
        _checkpoint();
    }

    function decimals() public view override returns (uint8) {
        return _getStorage()._decimals;
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
        EpochVaultStorage storage $ = _getStorage();
        if (receiver == address(0) || assets < $._limits.minDeposit || assets == 0) {
            revert InvalidInput();
        }
        uint64 epochId = $._currentEpoch;
        Epoch storage e = $._epochs[epochId];
        if (uint256(e.depositAssets) + assets > $._limits.maxEpochDeposits) {
            revert LimitExceeded();
        }

        _pullExact(_msgSender(), assets);
        $._cash += assets;
        $._pendingDeposits += assets;
        e.depositAssets += assets.toUint128();

        requestId = _newRequest(_msgSender(), receiver, epochId, RequestKind.Deposit, assets);
        _checkpoint();
        emit DepositRequested(requestId, epochId, _msgSender(), receiver, assets);
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
        EpochVaultStorage storage $ = _getStorage();
        uint64 epochId = $._currentEpoch;

        _transfer(owner, address(this), shares);
        $._escrowRedeemShares += shares;
        $._epochs[epochId].redeemShares += shares.toUint128();

        requestId = _newRequest(owner, receiver, epochId, RequestKind.Redeem, shares);
        emit RedeemRequested(requestId, epochId, owner, receiver, shares);
    }

    /// @notice Cancels a request while its epoch is still open.
    function cancel(uint256 requestId) external nonReentrant {
        EpochVaultStorage storage $ = _getStorage();
        Request storage r = $._requests[requestId];
        if (r.owner != _msgSender()) revert NotRequestOwner();
        if (r.status != RequestStatus.Requested || r.epoch != $._currentEpoch) {
            revert RequestNotCancellable();
        }
        r.status = RequestStatus.Cancelled;
        Epoch storage e = $._epochs[r.epoch];

        if (r.kind == RequestKind.Deposit) {
            e.depositAssets -= r.amount;
            $._pendingDeposits -= r.amount;
            $._cash -= r.amount;
            $._asset.safeTransfer(r.owner, r.amount);
            _checkpoint();
        } else {
            e.redeemShares -= r.amount;
            $._escrowRedeemShares -= r.amount;
            _transfer(address(this), r.owner, r.amount);
        }
        emit RequestCancelled(requestId);
    }

    /**
     * @notice Delivers a cleared deposit's shares or a funded redemption's
     *         assets to the recorded receiver. Callable by anyone.
     */
    function claim(uint256 requestId) external nonReentrant returns (uint256 amountOut) {
        EpochVaultStorage storage $ = _getStorage();
        Request storage r = $._requests[requestId];
        if (r.status != RequestStatus.Requested) revert RequestNotClaimable();
        Epoch storage e = $._epochs[r.epoch];

        if (r.kind == RequestKind.Deposit) {
            if (!e.depositsCleared) revert RequestNotClaimable();
            r.status = RequestStatus.Claimed;
            amountOut = uint256(r.amount).mulDiv(WAD, e.rateOffer);
            $._unclaimedDepositShares -= amountOut;
            _transfer(address(this), r.receiver, amountOut);
            emit DepositClaimed(requestId, r.receiver, amountOut);
        } else {
            if (!e.funded) revert RequestNotClaimable();
            r.status = RequestStatus.Claimed;
            amountOut = uint256(r.amount).mulDiv(e.priceRedeem, WAD);
            $._reserved -= amountOut;
            $._liabilities -= amountOut;
            $._cash -= amountOut;
            $._asset.safeTransfer(r.receiver, amountOut);
            _checkpoint();
            emit RedeemClaimed(requestId, r.receiver, amountOut);
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
        EpochVaultStorage storage $ = _getStorage();
        uint64 epochId = $._currentEpoch;
        Epoch storage e = $._epochs[epochId];
        EpochConfig memory c = $._epochConfig;

        uint256 elapsed = block.timestamp - e.openedAt;
        uint256 ticks = $._accountant.lastAcceptedTickId() - e.openTickId;
        if (!((elapsed >= c.minDuration && ticks >= c.minTicks) || elapsed >= c.maxDuration)) {
            revert EpochNotClosable();
        }

        e.closedAt = uint64(block.timestamp);
        emit EpochClosed(epochId, e.closedAt);
        _openEpoch(epochId + 1);
    }

    /**
     * @notice Clears the oldest closed epoch's deposits at the offer rate of the
     *         latest accepted Tick, which must have been observed after cutoff.
     * @dev Refuses Ticks flagged for a large down-move or overdue in-flight
     *      assets: a wrongly low rate would gift shares to depositors.
     */
    function clearDeposits() external nonReentrant whenNotPaused(DOMAIN_DEPOSIT_CLEARING) {
        EpochVaultStorage storage $ = _getStorage();
        uint64 epochId = $._nextDepositClear;
        if (epochId >= $._currentEpoch) revert NothingToClear();
        Epoch storage e = $._epochs[epochId];

        uint256 assets = e.depositAssets;
        uint64 tickId;
        uint256 rateOffer;
        uint256 minted;
        if (assets != 0) {
            ITickAccountant.Tick memory tick;
            (tickId, tick) = _usableTick(e.closedAt);
            if (tick.flags & DEPOSIT_BLOCKING_FLAGS != 0) revert TickNotUsable();
            rateOffer = tick.rateOffer;
            minted = assets.mulDiv(WAD, rateOffer);
            $._pendingDeposits -= assets;
            $._unclaimedDepositShares += minted;
            _mint(address(this), minted);
        }

        e.depositsCleared = true;
        e.depositTickId = tickId;
        e.rateOffer = rateOffer.toUint128();
        e.sharesMinted = minted.toUint128();
        $._nextDepositClear = epochId + 1;
        _checkpoint();
        emit DepositsCleared(epochId, tickId, assets, rateOffer, minted);
        _fund();
    }

    /**
     * @notice Clears the oldest closed epoch's redemptions at
     *         min(bid at epoch open, bid at the latest accepted Tick) and burns
     *         the escrowed shares. The owed assets become a liability, paid once
     *         the epoch is funded.
     */
    function clearRedeems() external nonReentrant whenNotPaused(DOMAIN_REDEEM_CLEARING) {
        EpochVaultStorage storage $ = _getStorage();
        uint64 epochId = $._nextRedeemClear;
        if (epochId >= $._currentEpoch) revert NothingToClear();
        Epoch storage e = $._epochs[epochId];

        uint256 shares = e.redeemShares;
        uint64 tickId;
        uint256 price;
        uint256 owed;
        if (shares != 0) {
            ITickAccountant.Tick memory tick;
            (tickId, tick) = _usableTick(e.closedAt);
            price = Math.min(e.openRateBid, tick.rateBid);
            owed = shares.mulDiv(price, WAD);
            $._escrowRedeemShares -= shares;
            $._liabilities += owed;
            _burn(address(this), shares);
        }

        e.redeemsCleared = true;
        e.redeemTickId = tickId;
        e.priceRedeem = price.toUint128();
        e.assetsOwed = owed.toUint128();
        $._nextRedeemClear = epochId + 1;
        _checkpoint();
        emit RedeemsCleared(epochId, tickId, shares, price, owed);
        _fund();
    }

    /// @notice Reserves free cash for cleared redemptions, strictly FIFO by epoch.
    function fund() external nonReentrant {
        _fund();
    }

    function _fund() internal {
        EpochVaultStorage storage $ = _getStorage();
        for (uint256 i; i < MAX_FUND_ITERATIONS; i++) {
            uint64 epochId = $._nextFund;
            if (epochId >= $._nextRedeemClear) return;
            Epoch storage e = $._epochs[epochId];
            uint256 owed = e.assetsOwed;
            if (owed > _freeCash()) return;
            $._reserved += owed;
            e.funded = true;
            $._nextFund = epochId + 1;
            emit EpochFunded(epochId, owed);
        }
    }

    /**
     * @dev Latest accepted Tick, required to be observed at or after `cutoff`,
     *      fresh, committed within the clearing delay, and not frozen.
     */
    function _usableTick(
        uint64 cutoff
    ) internal view returns (uint64 tickId, ITickAccountant.Tick memory tick) {
        EpochVaultStorage storage $ = _getStorage();
        ITickAccountant acct = $._accountant;
        (tickId, tick) = acct.latestAccepted();
        if (
            acct.frozen() ||
            tick.referenceTime < cutoff ||
            block.timestamp - tick.committedAt > acct.config().maxTickAge ||
            block.timestamp - tick.referenceTime > $._epochConfig.maxClearingDelay
        ) revert TickNotUsable();
    }

    function _openEpoch(uint64 epochId) internal {
        EpochVaultStorage storage $ = _getStorage();
        (uint64 tickId, ITickAccountant.Tick memory tick) = $._accountant.latestAccepted();
        Epoch storage e = $._epochs[epochId];
        e.openedAt = uint64(block.timestamp);
        e.openTickId = tickId;
        e.openRateBid = tick.rateBid;
        $._currentEpoch = epochId;
        emit EpochOpened(epochId, tickId, tick.rateBid);
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
        EpochVaultStorage storage $ = _getStorage();
        Limits memory l = $._limits;
        ITickAccountant acct = $._accountant;

        (uint64 tickId, ITickAccountant.Tick memory tick) = acct.latestAccepted();
        if (acct.frozen() || block.timestamp - tick.committedAt > l.instantMaxTickAge) {
            revert TickNotUsable();
        }

        uint256 price = uint256(tick.rateBid).mulDiv(WAD - l.instantFee, WAD);
        assets = shares.mulDiv(price, WAD);
        if (assets == 0 || assets < minAssets) revert SlippageExceeded();
        if (assets > l.maxInstantWithdrawal) revert LimitExceeded();
        _consumeInstant(assets, l.dailyInstantLimit);
        if (assets > _availableCash()) revert InsufficientFreeCash();

        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }
        _burn(owner, shares);
        $._cash -= assets;
        $._asset.safeTransfer(receiver, assets);
        _checkpoint();
        emit InstantRedeemed(owner, receiver, tickId, shares, assets);
    }

    function _consumeInstant(uint256 assets, uint256 capacity) internal {
        EpochVaultStorage storage $ = _getStorage();
        uint256 level = uint256($._instantLevel) +
            (block.timestamp - $._instantUpdatedAt).mulDiv(capacity, 1 days);
        if (level > capacity) level = capacity;
        if (assets > level) revert LimitExceeded();
        $._instantLevel = uint128(level - assets);
        $._instantUpdatedAt = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY AND THE HUB AGENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends free cash above the buffer to the hub ChainAgent.
     * @dev Cash owed to cleared-but-unfunded redemptions is never pushed out.
     */
    function pushToAgent(
        uint256 assets
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) whenNotPaused(DOMAIN_ALLOCATE) {
        EpochVaultStorage storage $ = _getStorage();
        address agent = $._hubAgent;
        if (agent == address(0) || assets == 0) revert InvalidInput();
        if ($._accountant.frozen()) revert TickNotUsable();
        uint256 available = _availableCash();
        uint256 buffer = minimumBuffer();
        if (available < buffer || assets > available - buffer) {
            revert InsufficientFreeCash();
        }

        $._cash -= assets;
        uint256 before = $._asset.balanceOf(address(this));
        $._asset.safeTransfer(agent, assets);
        if (before - $._asset.balanceOf(address(this)) != assets) {
            revert UnexpectedTokenAmount();
        }
        _checkpoint();
        emit PushedToAgent(agent, assets);
    }

    /// @notice Pulls `assets` back from the hub ChainAgent. Always allowed.
    function returnFunds(uint256 assets) external nonReentrant {
        EpochVaultStorage storage $ = _getStorage();
        if (_msgSender() != $._hubAgent) revert NotHubAgent();
        if (assets == 0) revert InvalidInput();
        _pullExact(_msgSender(), assets);
        $._cash += assets;
        _checkpoint();
        emit ReturnedFromAgent(_msgSender(), assets);
        _fund();
    }

    /// @inheritdoc IEpochVaultAccounting
    function mintFeeShares(address to, uint256 shares) external {
        if (_msgSender() != address(_getStorage()._accountant)) revert NotAccountant();
        _mint(to, shares);
        _checkpoint();
        emit FeeSharesMinted(to, shares);
    }

    /// @notice max(minimumBuffer, minBufferRatio * latest accepted bid NAV).
    function minimumBuffer() public view returns (uint256) {
        EpochVaultStorage storage $ = _getStorage();
        (, ITickAccountant.Tick memory tick) = $._accountant.latestAccepted();
        uint256 ratioBuffer = uint256(tick.navBid).mulDiv($._limits.minBufferRatio, WAD);
        return Math.max($._limits.minimumBuffer, ratioBuffer);
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

    function setEpochConfig(EpochConfig calldata c) external onlyTimelock {
        _setEpochConfig(c);
    }

    function setLimits(Limits calldata l) external onlyTimelock {
        _setLimits(l);
    }

    function setHubAgent(address agent) external onlyTimelock {
        if (agent == address(0)) revert InvalidConfig();
        _getStorage()._hubAgent = agent;
        emit HubAgentUpdated(agent);
    }

    function setTimelock(address timelock_) external onlyTimelock {
        _setTimelock(timelock_);
    }

    function _setEpochConfig(EpochConfig memory c) internal {
        if (c.maxDuration == 0 || c.minDuration > c.maxDuration || c.maxClearingDelay == 0) {
            revert InvalidConfig();
        }
        _getStorage()._epochConfig = c;
        emit EpochConfigUpdated(c);
    }

    function _setLimits(Limits memory l) internal {
        if (l.instantFee >= WAD || l.minBufferRatio > WAD) revert InvalidConfig();
        EpochVaultStorage storage $ = _getStorage();
        $._limits = l;
        if ($._instantLevel > l.dailyInstantLimit) {
            $._instantLevel = l.dailyInstantLimit;
        }
        emit LimitsUpdated(l);
    }

    function _setTimelock(address timelock_) internal {
        if (timelock_ == address(0)) revert InvalidConfig();
        _getStorage()._timelock = timelock_;
        emit TimelockUpdated(timelock_);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _newRequest(
        address owner,
        address receiver,
        uint64 epochId,
        RequestKind kind,
        uint256 amount
    ) internal returns (uint256 requestId) {
        EpochVaultStorage storage $ = _getStorage();
        requestId = $._nextRequestId++;
        $._requests[requestId] = Request({
            owner: owner,
            receiver: receiver,
            epoch: epochId,
            kind: kind,
            status: RequestStatus.Requested,
            amount: amount.toUint128()
        });
    }

    /// @dev Pulls exactly `assets`; fee-on-transfer or short transfers revert.
    function _pullExact(address from, uint256 assets) internal {
        IERC20Metadata asset_ = _getStorage()._asset;
        uint256 before = asset_.balanceOf(address(this));
        asset_.safeTransferFrom(from, address(this), assets);
        if (asset_.balanceOf(address(this)) - before != assets) {
            revert UnexpectedTokenAmount();
        }
    }

    function _freeCash() internal view returns (uint256) {
        EpochVaultStorage storage $ = _getStorage();
        return $._cash - $._pendingDeposits - $._reserved;
    }

    function _unfundedOwed() internal view returns (uint256) {
        EpochVaultStorage storage $ = _getStorage();
        return $._liabilities - $._reserved;
    }

    /// @dev Free cash not already owed to a cleared, unfunded redemption.
    ///      Instant exits and pushes to the agent can never jump the queue.
    function _availableCash() internal view returns (uint256) {
        uint256 free = _freeCash();
        uint256 owed = _unfundedOwed();
        return free > owed ? free - owed : 0;
    }

    function _checkpoint() internal {
        EpochVaultStorage storage $ = _getStorage();
        Checkpoint memory cp = Checkpoint({
            blockNumber: uint64(block.number),
            cash: $._cash.toUint128(),
            pendingDeposits: $._pendingDeposits.toUint128(),
            liabilities: $._liabilities.toUint128(),
            totalSupply: totalSupply().toUint128()
        });
        uint256 n = $._checkpoints.length;
        if (n != 0 && $._checkpoints[n - 1].blockNumber == block.number) {
            $._checkpoints[n - 1] = cp;
        } else {
            $._checkpoints.push(cp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(_getStorage()._asset);
    }

    function accountant() external view returns (address) {
        return address(_getStorage()._accountant);
    }

    function hubAgent() external view returns (address) {
        return _getStorage()._hubAgent;
    }

    function checkpointCount() external view returns (uint256) {
        return _getStorage()._checkpoints.length;
    }

    function checkpointAt(uint256 index) external view returns (Checkpoint memory) {
        return _getStorage()._checkpoints[index];
    }

    function currentEpoch() external view returns (uint64) {
        return _getStorage()._currentEpoch;
    }

    function getEpoch(uint64 epochId) external view returns (Epoch memory) {
        return _getStorage()._epochs[epochId];
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _getStorage()._requests[requestId];
    }

    function cursors() external view returns (uint64 nextDepositClear, uint64 nextRedeemClear, uint64 nextFund) {
        EpochVaultStorage storage $ = _getStorage();
        return ($._nextDepositClear, $._nextRedeemClear, $._nextFund);
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
        EpochVaultStorage storage $ = _getStorage();
        return (
            $._cash,
            $._pendingDeposits,
            $._liabilities,
            $._reserved,
            $._escrowRedeemShares,
            $._unclaimedDepositShares
        );
    }

    function freeCash() external view returns (uint256) {
        return _freeCash();
    }

    function epochConfig() external view returns (EpochConfig memory) {
        return _getStorage()._epochConfig;
    }

    function limits() external view returns (Limits memory) {
        return _getStorage()._limits;
    }

    function getTimelock() external view returns (address) {
        return _getStorage()._timelock;
    }
}
