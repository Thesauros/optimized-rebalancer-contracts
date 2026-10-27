// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessManager} from "../access/AccessManager.sol";
import {NavSnapshot} from "./NavSnapshot.sol";
import {ITickAccountant} from "./interfaces/ITickAccountant.sol";
import {IEpochVaultAccounting} from "./interfaces/IEpochVaultAccounting.sol";
import {MAX_MANAGEMENT_FEE, MAX_PERFORMANCE_FEE} from "../libraries/Constants.sol";

/**
 * @title TickAccountant
 * @notice Commits off-chain NAV snapshots as discrete, append-only Ticks.
 *
 * @dev Trust split (docs/tick-accounting-design.md §4.5):
 *      - the updater is trusted for remote position VALUES, within rate buckets;
 *      - the arithmetic, the encoding and the hub-side fields (cash, pending
 *        deposits, liabilities, shares) are verified here against the vault's
 *        own checkpoints, so they cannot be misreported;
 *      - a Tick outside the buckets or the spread bound is stored as
 *        Quarantined: it settles nothing until a later in-bounds Tick or an
 *        ADMIN ratification.
 *      Fees are computed on-chain from the recognized (bid) figures, with a
 *      high-water mark, and paid by minting vault shares.
 */
contract TickAccountant is Initializable, AccessManager, ITickAccountant {
    using Math for uint256;
    using SafeCast for uint256;
    using NavSnapshot for NavSnapshot.Snapshot;

    uint256 internal constant WAD = 1e18;

    bytes32 public constant NAV_UPDATER_ROLE = keccak256("NAV_UPDATER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint8 public constant FLAG_DOWN_BEYOND_DEPOSIT_LIMIT = 1 << 0;
    uint8 public constant FLAG_OVERDUE_IN_FLIGHT = 1 << 1;
    uint8 public constant FLAG_IN_FLIGHT_LIMIT = 1 << 2;
    /// @dev Set when at least one chain is above `maxChainExposure`. Unlike the
    ///      other flags it does not gate settlement: it only stops the hub agent
    ///      from sending more capital into the chains that are already over.
    uint8 public constant FLAG_CHAIN_EXPOSURE = 1 << 3;

    /// @notice Hard ceiling on the upward corridor, so no Timelock action can lift
    ///         it: at most a 2% rise per accepted Tick, refilled at 100% a year.
    ///         The downward bucket has no such ceiling because widening it only
    ///         admits losses, which is the conservative direction.
    uint128 public constant MAX_UP_CAPACITY = 0.02e18;
    uint128 public constant MAX_UP_REFILL_PER_SECOND = uint128(1e18) / 365 days;

    /// @custom:storage-location erc7201:thesauros.storage.TickAccountant
    struct TickAccountantStorage {
        IEpochVaultAccounting _vault;
        address _timelock;
        address _treasury;
        uint96 _managementFee;
        uint96 _performanceFee;
        uint64 _lastTickId;
        uint64 _lastAcceptedTickId;
        uint64 _lastCommitBlock;
        uint64 _lastFeeTime;
        bool _frozen;
        bool _quarantined;
        uint256 _highWaterMark;
        Config _config;
        Bucket _up;
        Bucket _down;
        uint64[] _chainIds;
        mapping(uint64 chainId => bool) _isChain;
        mapping(uint64 chainId => mapping(address agent => bool)) _isAgent;
        mapping(uint64 tickId => Tick) _ticks;
        // appended fields: keep the order above stable
        uint128 _maxChainExposure;
        mapping(uint64 chainId => bool) _overExposed;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.TickAccountant")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TickAccountantStorageLocation =
        0x275c27e0892c4e08d7ad6683f674b5fdf50673ed4093c27fc04ebfefcac22400;

    function _getStorage()
        private
        pure
        returns (TickAccountantStorage storage $)
    {
        assembly {
            $.slot := TickAccountantStorageLocation
        }
    }

    modifier onlyTimelock() {
        if (_msgSender() != _getStorage()._timelock) revert Unauthorized();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the accountant with Tick 0 at a 1:1 rate.
     * @dev The vault is bound afterwards with `setVault`, once, because the vault
     *      needs this contract's address at its own initialization.
     */
    function initialize(
        address admin_,
        address timelock_,
        address treasury_,
        uint64[] calldata chainIds_,
        Config calldata config_,
        Bucket calldata up_,
        Bucket calldata down_
    ) external initializer {
        if (admin_ == address(0)) revert InvalidConfig();
        __AccessManager_init(admin_);
        _setTimelock(timelock_);
        _setTreasury(treasury_);
        _setChains(chainIds_);
        _setConfig(config_);
        _setBuckets(up_, down_);

        TickAccountantStorage storage $ = _getStorage();
        $._highWaterMark = WAD;
        $._lastFeeTime = uint64(block.timestamp);
        $._lastCommitBlock = uint64(block.number);
        $._ticks[0] = Tick({
            referenceTime: uint64(block.timestamp),
            committedAt: uint64(block.timestamp),
            hubBlock: uint64(block.number),
            status: TickStatus.Accepted,
            flags: 0,
            rateBid: uint128(WAD),
            rateOffer: uint128(WAD),
            navBid: 0,
            navOffer: 0,
            navHash: bytes32(0)
        });
        emit TickCommitted(0, TickStatus.Accepted, 0, uint64(block.timestamp), uint64(block.number), WAD, WAD, 0, 0, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                               COMMIT
    //////////////////////////////////////////////////////////////*/

    /// @dev Figures computed while validating a commit.
    struct Candidate {
        uint64 hubBlock;
        uint8 flags;
        uint256 grossBid;
        uint256 grossOffer;
        uint256 prevRate;
        bytes32 navHash;
        NavSnapshot.Totals totals;
        bool[] overExposed;
    }

    /// @inheritdoc ITickAccountant
    function commitTick(
        NavSnapshot.Snapshot calldata s,
        uint256 hubCheckpointIndex
    ) external onlyRole(NAV_UPDATER_ROLE) {
        TickAccountantStorage storage $ = _getStorage();
        if (address($._vault) == address(0)) revert InvalidConfig();

        _validateIdentityAndTime($, s);
        s.validateEncoding();
        _validateMembership($, s);

        Candidate memory c;
        c.hubBlock = _validateHubBinding($, s, hubCheckpointIndex);
        c.totals = s.totals($._config.maxTransit);
        if (s.totalShares == 0 || c.totals.navBid == 0) revert ZeroShares();
        c.grossBid = c.totals.navBid.mulDiv(WAD, s.totalShares);
        c.grossOffer = c.totals.navOffer.mulDiv(WAD, s.totalShares);
        c.prevRate = $._ticks[$._lastAcceptedTickId].rateBid;
        uint8 exposureFlag;
        (exposureFlag, c.overExposed) = _chainExposure($, s, c.totals.navBid);
        c.flags = _riskFlags($._config, c.totals, c.grossBid, c.prevRate) | exposureFlag;
        c.navHash = s.hash();

        // the spread bound is tested first: `_consumeBuckets` spends rate
        // capacity, and capacity must not be spent on a Tick that is rejected
        bool inBounds = c.grossOffer <=
            c.grossBid.mulDiv(WAD + $._config.maxSpread, WAD) &&
            _consumeBuckets($, c.grossBid, c.prevRate);

        $._lastTickId = s.tickId;
        $._lastCommitBlock = uint64(block.number);

        if (!inBounds) {
            $._quarantined = true;
            _storeTick($, s.tickId, s.referenceTime, TickStatus.Quarantined, c, c.grossBid, c.grossOffer);
            return;
        }

        (uint256 rateBid, uint256 rateOffer) = _accrueFees($, s.tickId, c, s.totalShares);

        $._lastAcceptedTickId = s.tickId;
        if (rateBid > $._highWaterMark) {
            $._highWaterMark = rateBid;
        }
        _storeTick($, s.tickId, s.referenceTime, TickStatus.Accepted, c, rateBid, rateOffer);

        // exposure marks follow accepted Ticks only: a quarantined Tick is not
        // trusted for settlement, so it must not open or close sends either
        for (uint256 i; i < s.chains.length; i++) {
            $._overExposed[s.chains[i].chainId] = c.overExposed[i];
        }

        // an in-bounds Tick measured against the last accepted one resolves a
        // quarantine; a guardian freeze is only lifted by ADMIN (see `unfreeze`)
        $._quarantined = false;
    }

    function _validateIdentityAndTime(
        TickAccountantStorage storage $,
        NavSnapshot.Snapshot calldata s
    ) internal view {
        if (s.tickId != $._lastTickId + 1) revert InvalidTickId();

        Tick storage prev = $._ticks[$._lastTickId];
        if (
            s.referenceTime <= prev.referenceTime ||
            s.referenceTime > block.timestamp ||
            block.timestamp - s.referenceTime > $._config.maxSnapshotAge
        ) revert InvalidTime();

        if (block.timestamp < prev.committedAt + $._config.minTickInterval) {
            revert TooSoon();
        }
    }

    function _validateMembership(
        TickAccountantStorage storage $,
        NavSnapshot.Snapshot calldata s
    ) internal view {
        uint64[] storage configured = $._chainIds;
        if (s.chains.length != configured.length) revert ChainSetMismatch();
        for (uint256 i; i < configured.length; i++) {
            if (s.chains[i].chainId != configured[i]) revert ChainSetMismatch();
        }

        for (uint256 i; i < s.positions.length; i++) {
            // a chain can be dropped from the set while its agents stay marked,
            // so membership is checked explicitly: an unlisted chain would be
            // counted in `totals` but be invisible to `chainBids`
            if (!$._isChain[s.positions[i].chainId]) revert UnknownChain();
            if (!$._isAgent[s.positions[i].chainId][s.positions[i].holder]) {
                revert UnknownAgent();
            }
        }

        for (uint256 i; i < s.inFlight.length; i++) {
            if (
                !$._isChain[s.inFlight[i].srcChainId] ||
                !$._isChain[s.inFlight[i].dstChainId]
            ) revert UnknownChain();
        }
    }

    /**
     * @dev Binds the snapshot's hub reference block to a canonical block and the
     *      hub fields to the vault's checkpoint as of the end of that block.
     *      The block must be at or after the previous commit (so fee shares
     *      minted then are included) and within the 256-block `blockhash` window.
     */
    function _validateHubBinding(
        TickAccountantStorage storage $,
        NavSnapshot.Snapshot calldata s,
        uint256 index
    ) internal view returns (uint64 hubBlock) {
        uint256 hubIndex = type(uint256).max;
        for (uint256 i; i < s.chains.length; i++) {
            if (s.chains[i].chainId == block.chainid) {
                hubIndex = i;
                break;
            }
        }
        if (hubIndex == type(uint256).max) revert InvalidHubReference();

        hubBlock = s.chains[hubIndex].blockNumber;
        if (
            hubBlock >= block.number ||
            hubBlock < $._lastCommitBlock ||
            block.number - hubBlock > 256 ||
            blockhash(hubBlock) != s.chains[hubIndex].blockHash
        ) revert InvalidHubReference();

        IEpochVaultAccounting hubVault = $._vault;
        IEpochVaultAccounting.Checkpoint memory cp = hubVault.checkpointAt(index);
        if (cp.blockNumber > hubBlock) revert HubStateMismatch();
        if (index + 1 < hubVault.checkpointCount()) {
            if (hubVault.checkpointAt(index + 1).blockNumber <= hubBlock) {
                revert HubStateMismatch();
            }
        }
        if (
            s.hubCash != cp.cash ||
            s.pendingDeposits != cp.pendingDeposits ||
            s.liabilities != cp.liabilities ||
            s.totalShares != cp.totalSupply
        ) revert HubStateMismatch();
    }

    function _riskFlags(
        Config memory cfg,
        NavSnapshot.Totals memory t,
        uint256 grossBid,
        uint256 prevRate
    ) internal pure returns (uint8 flags) {
        if (grossBid < prevRate.mulDiv(WAD - cfg.depositClearingMaxDown, WAD)) {
            flags |= FLAG_DOWN_BEYOND_DEPOSIT_LIMIT;
        }
        if (t.overdueInFlight > cfg.maxOverdueInFlight) {
            flags |= FLAG_OVERDUE_IN_FLIGHT;
        }
        if (t.inFlight > t.navBid.mulDiv(cfg.maxInFlightRatio, WAD)) {
            flags |= FLAG_IN_FLIGHT_LIMIT;
        }
    }

    /**
     * @dev Re-derives per-chain concentration from this Tick's own positions and
     *      returns `FLAG_CHAIN_EXPOSURE` when any chain is over the cap. The cap
     *      is measured against gross bid assets, not NAV: NAV nets off pending
     *      deposits and liabilities, so a large deposit epoch would inflate every
     *      chain's apparent share past 100% and latch the flag on for a reason
     *      that has nothing to do with concentration. In-flight value belongs to
     *      no chain, so it sits in the denominator only, which makes the shares
     *      sum to slightly under 100% — the conservative direction.
     *      Because the cap gates sends *into* a chain, a chain that is over can
     *      always be brought back down by sending capital out of it; settlement is
     *      never affected. A cap of zero disables the check; the marks it returns
     *      are written by `commitTick` only when the Tick is accepted, so a cap of
     *      zero clears every mark on the next accepted Tick.
     */
    function _chainExposure(
        TickAccountantStorage storage $,
        NavSnapshot.Snapshot calldata s,
        uint256 navBid
    ) internal view returns (uint8 flags, bool[] memory over) {
        uint256 cap = uint256($._maxChainExposure);
        uint256[] memory bids = s.chainBids(uint64(block.chainid));
        // gross bid assets = navBid + the deductions NAV was netted by
        uint256 gross = navBid + s.pendingDeposits + s.liabilities;
        uint256 limit = gross.mulDiv(cap, WAD);
        over = new bool[](s.chains.length);
        for (uint256 i; i < s.chains.length; i++) {
            over[i] = cap != 0 && bids[i] > limit;
            if (over[i]) flags |= FLAG_CHAIN_EXPOSURE;
        }
    }

    /**
     * @dev Refills both buckets for elapsed time, then consumes the move from the
     *      bucket of its direction. Returns false (and consumes nothing) when the
     *      move exceeds the available level. Over any window W the total movement
     *      in one direction is therefore bounded by capacity + refill * W.
     */
    function _consumeBuckets(
        TickAccountantStorage storage $,
        uint256 grossBid,
        uint256 prevRate
    ) internal returns (bool) {
        _refill($._up);
        _refill($._down);

        if (grossBid >= prevRate) {
            uint256 move = (grossBid - prevRate).mulDiv(WAD, prevRate, Math.Rounding.Ceil);
            if (move > $._up.level) return false;
            $._up.level -= uint128(move);
        } else {
            uint256 move = (prevRate - grossBid).mulDiv(WAD, prevRate, Math.Rounding.Ceil);
            if (move > $._down.level) return false;
            $._down.level -= uint128(move);
        }
        return true;
    }

    function _refill(Bucket storage b) internal {
        uint256 dt = block.timestamp - b.updatedAt;
        uint256 level = uint256(b.level) + dt * b.refillPerSecond;
        b.level = uint128(level > b.capacity ? b.capacity : level);
        b.updatedAt = uint64(block.timestamp);
    }

    /**
     * @dev Management fee on recognized NAV over elapsed time; performance fee on
     *      the bid rate above the high-water mark. Paid in shares, so NAV does not
     *      move and the net rates are the gross rates times (nav - fee) / nav.
     *      Fee shares are minted against the current supply, which applies the
     *      same dilution fraction whatever changed since the reference block.
     */
    function _accrueFees(
        TickAccountantStorage storage $,
        uint64 tickId,
        Candidate memory c,
        uint256 snapshotShares
    ) internal returns (uint256 rateBid, uint256 rateOffer) {
        uint256 navBid = c.totals.navBid;
        (uint256 mgmt, uint256 perf) = _feeAssets($, navBid, c.grossBid, snapshotShares);
        $._lastFeeTime = uint64(block.timestamp);

        uint256 fee = mgmt + perf;
        if (fee == 0) {
            return (c.grossBid, c.grossOffer);
        }

        uint256 feeShares = $._vault.totalSupply().mulDiv(fee, navBid - fee);
        if (feeShares != 0) {
            $._vault.mintFeeShares($._treasury, feeShares);
        }

        rateBid = c.grossBid.mulDiv(navBid - fee, navBid);
        rateOffer = c.grossOffer.mulDiv(navBid - fee, navBid);
        emit FeesAccrued(tickId, mgmt, perf, feeShares);
    }

    /// @dev Management fee over elapsed time on recognized NAV, then performance
    ///      fee on the post-management bid rate above the high-water mark. The
    ///      sum is kept strictly below NAV.
    function _feeAssets(
        TickAccountantStorage storage $,
        uint256 navBid,
        uint256 grossBid,
        uint256 shares
    ) internal view returns (uint256 mgmt, uint256 perf) {
        uint256 dt = block.timestamp - $._lastFeeTime;
        mgmt = navBid.mulDiv(uint256($._managementFee) * dt, 365 days * WAD);
        if (mgmt >= navBid) mgmt = navBid - 1;

        uint256 hwm = $._highWaterMark;
        uint256 rateAfterMgmt = grossBid.mulDiv(navBid - mgmt, navBid);
        if ($._performanceFee != 0 && rateAfterMgmt > hwm) {
            perf = (rateAfterMgmt - hwm).mulDiv(shares, WAD).mulDiv($._performanceFee, WAD);
            if (mgmt + perf >= navBid) perf = navBid - mgmt - 1;
        }
    }

    function _storeTick(
        TickAccountantStorage storage $,
        uint64 tickId,
        uint64 referenceTime,
        TickStatus status,
        Candidate memory c,
        uint256 rateBid,
        uint256 rateOffer
    ) internal {
        Tick storage tick = $._ticks[tickId];
        tick.referenceTime = referenceTime;
        tick.committedAt = uint64(block.timestamp);
        tick.hubBlock = c.hubBlock;
        tick.status = status;
        tick.flags = c.flags;
        tick.rateBid = rateBid.toUint128();
        tick.rateOffer = rateOffer.toUint128();
        tick.navBid = c.totals.navBid.toUint128();
        tick.navOffer = c.totals.navOffer.toUint128();
        tick.navHash = c.navHash;
        emit TickCommitted(
            tickId,
            status,
            c.flags,
            referenceTime,
            c.hubBlock,
            rateBid,
            rateOffer,
            c.totals.navBid,
            c.totals.navOffer,
            c.navHash
        );
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE AND EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Makes the latest, quarantined Tick settle-able.
     * @dev For real large losses or recoveries. No fee is charged on a ratified
     *      Tick; the high-water mark is not raised by it.
     *      Split by direction. A Tick whose bid rate is at or below the last
     *      accepted one is the conservative direction: redemptions are priced at
     *      `min(openRateBid, rateBid)`, and a down-move beyond
     *      `depositClearingMaxDown` cannot clear deposits, so ADMIN may ratify it
     *      at once and a real loss is not held up. An upward re-pricing is the
     *      one that could pay redeemers from the remaining holders, so it needs
     *      the Timelock. The NAV service stops re-committing while a quarantine
     *      stands and the move exceeds the bucket, so the Tick stays the latest
     *      through the delay.
     */
    function ratifyTick(uint64 tickId) external {
        TickAccountantStorage storage $ = _getStorage();
        Tick storage tick = $._ticks[tickId];
        if (tickId != $._lastTickId || tick.status != TickStatus.Quarantined) {
            revert NotQuarantined();
        }
        if (tick.rateBid > $._ticks[$._lastAcceptedTickId].rateBid) {
            if (_msgSender() != $._timelock) revert Unauthorized();
        } else if (!hasRole(ADMIN_ROLE, _msgSender()) && _msgSender() != $._timelock) {
            revert Unauthorized();
        }
        tick.status = TickStatus.Ratified;
        $._lastAcceptedTickId = tickId;
        $._quarantined = false;
        emit TickRatified(tickId, _msgSender());
    }

    /// @notice Freezes settlement (clearing, instant exits, hub bridge sends).
    function freeze() external {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(ADMIN_ROLE, _msgSender())) {
            revert Unauthorized();
        }
        _getStorage()._frozen = true;
        emit FrozenSet(true, _msgSender());
    }

    function unfreeze() external onlyRole(ADMIN_ROLE) {
        _getStorage()._frozen = false;
        emit FrozenSet(false, _msgSender());
    }

    /// @notice One-time binding of the hub vault.
    function setVault(address vault_) external onlyRole(ADMIN_ROLE) {
        TickAccountantStorage storage $ = _getStorage();
        if (address($._vault) != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert InvalidConfig();
        $._vault = IEpochVaultAccounting(vault_);
        emit VaultSet(vault_);
    }

    function setConfig(Config calldata config_) external onlyTimelock {
        _setConfig(config_);
    }

    function setBuckets(Bucket calldata up_, Bucket calldata down_) external onlyTimelock {
        _setBuckets(up_, down_);
    }

    /**
     * @notice Caps one chain's share of gross bid assets, as a 1e18 fraction.
     *         Zero, the default, disables the check.
     * @dev Kept out of `Config` on purpose: the cap is a concentration policy
     *      that changes with the chain set, and a separate setter leaves every
     *      existing `Config` caller untouched. It takes effect on the next
     *      committed Tick. Setting it below the current allocation blocks sends
     *      into the chains that are already over until capital is moved out, so
     *      raise it before adding a chain and lower it only with an allocation
     *      plan.
     */
    function setMaxChainExposure(uint128 ratio) external onlyTimelock {
        if (ratio > WAD) revert InvalidConfig();
        _getStorage()._maxChainExposure = ratio;
        emit MaxChainExposureUpdated(ratio);
    }

    function setChains(uint64[] calldata chainIds_) external onlyTimelock {
        _setChains(chainIds_);
    }

    function setAgent(uint64 chainId, address agent, bool allowed) external onlyTimelock {
        TickAccountantStorage storage $ = _getStorage();
        if (!$._isChain[chainId] || agent == address(0)) revert InvalidConfig();
        $._isAgent[chainId][agent] = allowed;
        emit AgentUpdated(chainId, agent, allowed);
    }

    /// @dev Takes effect from the next accepted Tick; time already elapsed is
    ///      charged at the new rate, so change fees right after a Tick.
    function setFees(uint96 managementFee_, uint96 performanceFee_) external onlyTimelock {
        if (managementFee_ > MAX_MANAGEMENT_FEE || performanceFee_ > MAX_PERFORMANCE_FEE) {
            revert InvalidConfig();
        }
        TickAccountantStorage storage $ = _getStorage();
        $._managementFee = managementFee_;
        $._performanceFee = performanceFee_;
        emit FeesUpdated(managementFee_, performanceFee_);
    }

    function setTreasury(address treasury_) external onlyTimelock {
        _setTreasury(treasury_);
    }

    function setTimelock(address timelock_) external onlyTimelock {
        _setTimelock(timelock_);
    }

    function _setConfig(Config memory c) internal {
        if (
            c.maxSnapshotAge == 0 ||
            c.maxTickAge == 0 ||
            c.maxTransit == 0 ||
            c.depositClearingMaxDown >= WAD ||
            c.maxInFlightRatio > WAD
        ) revert InvalidConfig();
        _getStorage()._config = c;
        emit ConfigUpdated(c);
    }

    function _setBuckets(Bucket memory up_, Bucket memory down_) internal {
        if (
            up_.capacity == 0 ||
            up_.capacity > MAX_UP_CAPACITY ||
            up_.refillPerSecond > MAX_UP_REFILL_PER_SECOND ||
            down_.capacity == 0 ||
            down_.capacity >= WAD
        ) {
            revert InvalidConfig();
        }
        TickAccountantStorage storage $ = _getStorage();
        $._up = Bucket(up_.capacity, up_.refillPerSecond, up_.capacity, uint64(block.timestamp));
        $._down = Bucket(down_.capacity, down_.refillPerSecond, down_.capacity, uint64(block.timestamp));
        emit BucketsUpdated($._up, $._down);
    }

    function _setChains(uint64[] calldata chainIds_) internal {
        TickAccountantStorage storage $ = _getStorage();
        bool hasHub;
        for (uint256 i; i < $._chainIds.length; i++) {
            $._isChain[$._chainIds[i]] = false;
        }
        for (uint256 i; i < chainIds_.length; i++) {
            if (i > 0 && chainIds_[i] <= chainIds_[i - 1]) revert InvalidConfig();
            if (chainIds_[i] == block.chainid) hasHub = true;
            $._isChain[chainIds_[i]] = true;
        }
        if (!hasHub) revert InvalidConfig();
        $._chainIds = chainIds_;
        emit ChainsUpdated(chainIds_);
    }

    function _setTreasury(address treasury_) internal {
        if (treasury_ == address(0)) revert InvalidConfig();
        _getStorage()._treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function _setTimelock(address timelock_) internal {
        if (timelock_ == address(0)) revert InvalidConfig();
        _getStorage()._timelock = timelock_;
        emit TimelockUpdated(timelock_);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function lastTickId() external view returns (uint64) {
        return _getStorage()._lastTickId;
    }

    function lastAcceptedTickId() external view returns (uint64) {
        return _getStorage()._lastAcceptedTickId;
    }

    function getTick(uint64 tickId) external view returns (Tick memory) {
        return _getStorage()._ticks[tickId];
    }

    function latestAccepted() external view returns (uint64 tickId, Tick memory tick) {
        TickAccountantStorage storage $ = _getStorage();
        tickId = $._lastAcceptedTickId;
        tick = $._ticks[tickId];
    }

    /// @notice True while a quarantine is unresolved or a guardian freeze is on.
    function frozen() external view returns (bool) {
        TickAccountantStorage storage $ = _getStorage();
        return $._frozen || $._quarantined;
    }

    function quarantined() external view returns (bool) {
        return _getStorage()._quarantined;
    }

    function config() external view returns (Config memory) {
        return _getStorage()._config;
    }

    /// @notice False while frozen, stale, or the latest accepted Tick carries an
    ///         in-flight breaker flag. Read by the hub ChainAgent before sends.
    function bridgeSendsAllowed() external view returns (bool) {
        return _bridgeSendsAllowed(_getStorage());
    }

    /// @notice `bridgeSendsAllowed` narrowed to one destination: also false while
    ///         that chain is above `maxChainExposure`, so capital can still flow
    ///         out of an over-concentrated chain but not further into it.
    function chainSendAllowed(uint64 dstChainId) external view returns (bool) {
        TickAccountantStorage storage $ = _getStorage();
        return _bridgeSendsAllowed($) && !$._overExposed[dstChainId];
    }

    function _bridgeSendsAllowed(
        TickAccountantStorage storage $
    ) internal view returns (bool) {
        Tick storage tick = $._ticks[$._lastAcceptedTickId];
        return
            !$._frozen &&
            !$._quarantined &&
            block.timestamp - tick.committedAt <= $._config.maxTickAge &&
            tick.flags & (FLAG_OVERDUE_IN_FLIGHT | FLAG_IN_FLIGHT_LIMIT) == 0;
    }

    /// @notice One chain's maximum share of gross bid assets, as a 1e18 fraction.
    ///         Zero, the default, disables the check.
    function maxChainExposure() external view returns (uint128) {
        return _getStorage()._maxChainExposure;
    }

    /// @notice Whether the latest committed Tick put this chain over the cap.
    function isChainOverExposed(uint64 chainId) external view returns (bool) {
        return _getStorage()._overExposed[chainId];
    }

    function buckets() external view returns (Bucket memory up, Bucket memory down) {
        TickAccountantStorage storage $ = _getStorage();
        return ($._up, $._down);
    }

    function chainIds() external view returns (uint64[] memory) {
        return _getStorage()._chainIds;
    }

    function isAgent(uint64 chainId, address agent) external view returns (bool) {
        return _getStorage()._isAgent[chainId][agent];
    }

    function vault() external view returns (address) {
        return address(_getStorage()._vault);
    }

    function getFees() external view returns (uint96 managementFee, uint96 performanceFee, uint256 highWaterMark, address treasury) {
        TickAccountantStorage storage $ = _getStorage();
        return ($._managementFee, $._performanceFee, $._highWaterMark, $._treasury);
    }

    function getTimelock() external view returns (address) {
        return _getStorage()._timelock;
    }
}
