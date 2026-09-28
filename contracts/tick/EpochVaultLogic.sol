// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITickAccountant} from "./interfaces/ITickAccountant.sol";
import {IEpochVault} from "./interfaces/IEpochVault.sol";
import {IEpochVaultAccounting} from "./interfaces/IEpochVaultAccounting.sol";
import {EpochVaultStorage} from "./EpochVaultStorage.sol";

/**
 * @title EpochVaultLogic
 * @notice Epoch lifecycle, clearing, funding, instant-exit limits, buffer and
 *         checkpoints of the EpochVault, as an externally linked library.
 *
 * @dev Runs under DELEGATECALL from the vault: storage, token balances and
 *      emitted events are the vault's. It never touches share balances; minting,
 *      burning and share transfers stay in the vault, which then calls
 *      `checkpoint` with the resulting supply. No state of its own, no roles:
 *      every external function is reachable only through the vault's gated
 *      entry points.
 */
library EpochVaultLogic {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20Metadata;

    uint256 internal constant WAD = 1e18;

    /// @dev Tick flags that block deposit clearing (mirrors TickAccountant).
    uint8 internal constant DEPOSIT_BLOCKING_FLAGS = (1 << 0) | (1 << 1);

    /// @dev Upper bound on epochs funded per call, to keep gas bounded.
    uint256 internal constant MAX_FUND_ITERATIONS = 16;

    /*//////////////////////////////////////////////////////////////
                               REQUESTS
    //////////////////////////////////////////////////////////////*/

    function requestDeposit(
        EpochVaultStorage.Layout storage $,
        address caller,
        address receiver,
        uint256 assets,
        uint256 supply
    ) external returns (uint256 requestId) {
        if (receiver == address(0) || assets == 0 || assets < $.limits.minDeposit) {
            revert IEpochVault.InvalidInput();
        }
        uint64 epochId = $.currentEpoch;
        IEpochVault.Epoch storage e = $.epochs[epochId];
        if (uint256(e.depositAssets) + assets > $.limits.maxEpochDeposits) {
            revert IEpochVault.LimitExceeded();
        }

        _pullExact($, caller, assets);
        $.cash += assets;
        $.pendingDeposits += assets;
        e.depositAssets += assets.toUint128();

        requestId = _newRequest($, caller, receiver, epochId, IEpochVault.RequestKind.Deposit, assets);
        _checkpoint($, supply);
        emit IEpochVault.DepositRequested(requestId, epochId, caller, receiver, assets);
    }

    /// @dev Called after the vault moved `shares` from `owner` into escrow.
    function recordRedeem(
        EpochVaultStorage.Layout storage $,
        address owner,
        address receiver,
        uint256 shares
    ) external returns (uint256 requestId) {
        uint64 epochId = $.currentEpoch;
        $.escrowRedeemShares += shares;
        $.epochs[epochId].redeemShares += shares.toUint128();
        requestId = _newRequest($, owner, receiver, epochId, IEpochVault.RequestKind.Redeem, shares);
        emit IEpochVault.RedeemRequested(requestId, epochId, owner, receiver, shares);
    }

    /**
     * @dev Deposit cancels are refunded here. For a redeem cancel the vault
     *      returns `sharesToReturn` from escrow to `owner`.
     */
    function cancel(
        EpochVaultStorage.Layout storage $,
        address caller,
        uint256 requestId,
        uint256 supply
    ) external returns (address owner, uint256 sharesToReturn) {
        IEpochVault.Request storage r = $.requests[requestId];
        if (r.owner != caller) revert IEpochVault.NotRequestOwner();
        if (r.status != IEpochVault.RequestStatus.Requested) {
            revert IEpochVault.RequestNotCancellable();
        }
        IEpochVault.Epoch storage e = $.epochs[r.epoch];
        if (r.epoch != $.currentEpoch) {
            // Past the cutoff only a deposit may still be withdrawn, and only
            // until its epoch is cleared. Pending deposits are excluded from NAV,
            // so the refund is NAV-neutral: no price changes, and nobody can use
            // it to leave at a pre-loss rate. A redemption is refused because its
            // price is not fixed until clearing, so a late cancel would hand the
            // holder a free option on the epoch's yield at the remaining holders'
            // cost. Without this, a deposit caught in an epoch that closed while
            // the accountant was frozen or quarantined has no exit at all:
            // clearing needs a usable Tick and cancellation needed an open epoch.
            if (r.kind != IEpochVault.RequestKind.Deposit || e.depositsCleared) {
                revert IEpochVault.RequestNotCancellable();
            }
        }
        r.status = IEpochVault.RequestStatus.Cancelled;
        owner = r.owner;

        if (r.kind == IEpochVault.RequestKind.Deposit) {
            e.depositAssets -= r.amount;
            $.pendingDeposits -= r.amount;
            $.cash -= r.amount;
            $.asset.safeTransfer(owner, r.amount);
            _checkpoint($, supply);
        } else {
            e.redeemShares -= r.amount;
            $.escrowRedeemShares -= r.amount;
            sharesToReturn = r.amount;
        }
        emit IEpochVault.RequestCancelled(requestId);
    }

    /**
     * @dev Pays a funded redemption here. For a cleared deposit, returns the
     *      shares the vault must transfer from escrow to `receiver`.
     */
    function claim(
        EpochVaultStorage.Layout storage $,
        uint256 requestId,
        uint256 supply
    ) external returns (address receiver, uint256 amountOut, bool isDeposit) {
        IEpochVault.Request storage r = $.requests[requestId];
        if (r.status != IEpochVault.RequestStatus.Requested) revert IEpochVault.RequestNotClaimable();
        IEpochVault.Epoch storage e = $.epochs[r.epoch];
        receiver = r.receiver;

        if (r.kind == IEpochVault.RequestKind.Deposit) {
            if (!e.depositsCleared) revert IEpochVault.RequestNotClaimable();
            r.status = IEpochVault.RequestStatus.Claimed;
            isDeposit = true;
            amountOut = uint256(r.amount).mulDiv(WAD, e.rateOffer);
            $.unclaimedDepositShares -= amountOut;
            emit IEpochVault.DepositClaimed(requestId, receiver, amountOut);
        } else {
            if (!e.funded) revert IEpochVault.RequestNotClaimable();
            r.status = IEpochVault.RequestStatus.Claimed;
            amountOut = uint256(r.amount).mulDiv(e.priceRedeem, WAD);
            $.reserved -= amountOut;
            $.liabilities -= amountOut;
            $.cash -= amountOut;
            $.asset.safeTransfer(receiver, amountOut);
            _checkpoint($, supply);
            emit IEpochVault.RedeemClaimed(requestId, receiver, amountOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EPOCH LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function openEpoch(EpochVaultStorage.Layout storage $, uint64 epochId) external {
        _openEpoch($, epochId);
    }

    function closeEpoch(EpochVaultStorage.Layout storage $) external {
        uint64 epochId = $.currentEpoch;
        IEpochVault.Epoch storage e = $.epochs[epochId];
        IEpochVault.EpochConfig memory c = $.epochConfig;

        uint256 elapsed = block.timestamp - e.openedAt;
        uint256 ticks = $.accountant.lastAcceptedTickId() - e.openTickId;
        if (!((elapsed >= c.minDuration && ticks >= c.minTicks) || elapsed >= c.maxDuration)) {
            revert IEpochVault.EpochNotClosable();
        }

        e.closedAt = uint64(block.timestamp);
        emit IEpochVault.EpochClosed(epochId, e.closedAt);
        _openEpoch($, epochId + 1);
    }

    /**
     * @dev Books the oldest closed epoch's deposits at the offer rate and
     *      returns the shares the vault must mint to itself.
     */
    function clearDeposits(EpochVaultStorage.Layout storage $) external returns (uint256 minted) {
        uint64 epochId = $.nextDepositClear;
        if (epochId >= $.currentEpoch) revert IEpochVault.NothingToClear();
        IEpochVault.Epoch storage e = $.epochs[epochId];

        uint256 assets = e.depositAssets;
        uint64 tickId;
        uint256 rateOffer;
        if (assets != 0) {
            ITickAccountant.Tick memory tick;
            (tickId, tick) = _usableTick($, e.closedAt);
            if (tick.flags & DEPOSIT_BLOCKING_FLAGS != 0) revert IEpochVault.TickNotUsable();
            rateOffer = tick.rateOffer;
            minted = assets.mulDiv(WAD, rateOffer);
            $.pendingDeposits -= assets;
            $.unclaimedDepositShares += minted;
        }

        e.depositsCleared = true;
        e.depositTickId = tickId;
        e.rateOffer = rateOffer.toUint128();
        e.sharesMinted = minted.toUint128();
        $.nextDepositClear = epochId + 1;
        emit IEpochVault.DepositsCleared(epochId, tickId, assets, rateOffer, minted);
    }

    /**
     * @dev Books the oldest closed epoch's redemptions at
     *      min(bid at epoch open, bid at the latest accepted Tick) and returns
     *      the escrowed shares the vault must burn.
     */
    function clearRedeems(EpochVaultStorage.Layout storage $) external returns (uint256 shares) {
        uint64 epochId = $.nextRedeemClear;
        if (epochId >= $.currentEpoch) revert IEpochVault.NothingToClear();
        IEpochVault.Epoch storage e = $.epochs[epochId];

        shares = e.redeemShares;
        uint64 tickId;
        uint256 price;
        uint256 owed;
        if (shares != 0) {
            ITickAccountant.Tick memory tick;
            (tickId, tick) = _usableTick($, e.closedAt);
            price = Math.min(e.openRateBid, tick.rateBid);
            owed = shares.mulDiv(price, WAD);
            $.escrowRedeemShares -= shares;
            $.liabilities += owed;
        }

        e.redeemsCleared = true;
        e.redeemTickId = tickId;
        e.priceRedeem = price.toUint128();
        e.assetsOwed = owed.toUint128();
        $.nextRedeemClear = epochId + 1;
        emit IEpochVault.RedeemsCleared(epochId, tickId, shares, price, owed);
    }

    /// @notice Reserves free cash for cleared redemptions, strictly FIFO by epoch.
    function fund(EpochVaultStorage.Layout storage $) external {
        _fund($);
    }

    /*//////////////////////////////////////////////////////////////
                         INSTANT EXIT AND LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Called after the vault burned `shares` from the owner. Prices at the
     *      latest bid minus the fee, enforces freshness and limits, and pays.
     */
    function instantRedeem(
        EpochVaultStorage.Layout storage $,
        uint256 shares,
        address receiver,
        uint256 minAssets
    ) external returns (uint64 tickId, uint256 assets) {
        IEpochVault.Limits memory l = $.limits;
        ITickAccountant acct = $.accountant;

        ITickAccountant.Tick memory tick;
        (tickId, tick) = acct.latestAccepted();
        if (acct.frozen() || block.timestamp - tick.committedAt > l.instantMaxTickAge) {
            revert IEpochVault.TickNotUsable();
        }

        uint256 price = uint256(tick.rateBid).mulDiv(WAD - l.instantFee, WAD);
        assets = shares.mulDiv(price, WAD);
        if (assets == 0 || assets < minAssets) revert IEpochVault.SlippageExceeded();
        if (assets > l.maxInstantWithdrawal) revert IEpochVault.LimitExceeded();
        _consumeInstant($, assets, l.dailyInstantLimit);
        if (assets > _availableCash($)) revert IEpochVault.InsufficientFreeCash();

        $.cash -= assets;
        $.asset.safeTransfer(receiver, assets);
    }

    /// @dev Cash owed to cleared-but-unfunded redemptions is never pushed out.
    function pushToAgent(EpochVaultStorage.Layout storage $, uint256 assets, uint256 supply) external {
        address agent = $.hubAgent;
        if (agent == address(0) || assets == 0) revert IEpochVault.InvalidInput();
        if ($.accountant.frozen()) revert IEpochVault.TickNotUsable();
        uint256 available = _availableCash($);
        uint256 buffer = _minimumBuffer($);
        if (available < buffer || assets > available - buffer) {
            revert IEpochVault.InsufficientFreeCash();
        }

        $.cash -= assets;
        uint256 before = $.asset.balanceOf(address(this));
        $.asset.safeTransfer(agent, assets);
        if (before - $.asset.balanceOf(address(this)) != assets) {
            revert IEpochVault.UnexpectedTokenAmount();
        }
        _checkpoint($, supply);
        emit IEpochVault.PushedToAgent(agent, assets);
    }

    function returnFunds(EpochVaultStorage.Layout storage $, address caller, uint256 assets, uint256 supply) external {
        if (caller != $.hubAgent) revert IEpochVault.NotHubAgent();
        if (assets == 0) revert IEpochVault.InvalidInput();
        _pullExact($, caller, assets);
        $.cash += assets;
        _checkpoint($, supply);
        emit IEpochVault.ReturnedFromAgent(caller, assets);
        _fund($);
    }

    /// @dev Pulls exactly `assets` from `from`; fee-on-transfer or short transfers revert.
    function pullExact(EpochVaultStorage.Layout storage $, address from, uint256 assets) external {
        _pullExact($, from, assets);
    }

    function checkpoint(EpochVaultStorage.Layout storage $, uint256 supply) external {
        _checkpoint($, supply);
    }

    function minimumBuffer(EpochVaultStorage.Layout storage $) external view returns (uint256) {
        return _minimumBuffer($);
    }

    function freeCash(EpochVaultStorage.Layout storage $) external view returns (uint256) {
        return _freeCash($);
    }

    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setEpochConfig(EpochVaultStorage.Layout storage $, IEpochVault.EpochConfig memory c) external {
        if (c.maxDuration == 0 || c.minDuration > c.maxDuration || c.maxClearingDelay == 0) {
            revert IEpochVault.InvalidConfig();
        }
        $.epochConfig = c;
        emit IEpochVault.EpochConfigUpdated(c);
    }

    function setLimits(EpochVaultStorage.Layout storage $, IEpochVault.Limits memory l) external {
        if (l.instantFee >= WAD || l.minBufferRatio > WAD) revert IEpochVault.InvalidConfig();
        $.limits = l;
        if ($.instantLevel > l.dailyInstantLimit) {
            $.instantLevel = l.dailyInstantLimit;
        }
        emit IEpochVault.LimitsUpdated(l);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _openEpoch(EpochVaultStorage.Layout storage $, uint64 epochId) private {
        (uint64 tickId, ITickAccountant.Tick memory tick) = $.accountant.latestAccepted();
        IEpochVault.Epoch storage e = $.epochs[epochId];
        e.openedAt = uint64(block.timestamp);
        e.openTickId = tickId;
        e.openRateBid = tick.rateBid;
        $.currentEpoch = epochId;
        emit IEpochVault.EpochOpened(epochId, tickId, tick.rateBid);
    }

    function _fund(EpochVaultStorage.Layout storage $) private {
        for (uint256 i; i < MAX_FUND_ITERATIONS; i++) {
            uint64 epochId = $.nextFund;
            if (epochId >= $.nextRedeemClear) return;
            IEpochVault.Epoch storage e = $.epochs[epochId];
            uint256 owed = e.assetsOwed;
            if (owed > _freeCash($)) return;
            $.reserved += owed;
            e.funded = true;
            $.nextFund = epochId + 1;
            emit IEpochVault.EpochFunded(epochId, owed);
        }
    }

    /**
     * @dev Latest accepted Tick, required to be observed at or after `cutoff`,
     *      fresh, committed within the clearing delay, and not frozen.
     */
    function _usableTick(
        EpochVaultStorage.Layout storage $,
        uint64 cutoff
    ) private view returns (uint64 tickId, ITickAccountant.Tick memory tick) {
        ITickAccountant acct = $.accountant;
        (tickId, tick) = acct.latestAccepted();
        if (
            acct.frozen() ||
            tick.referenceTime < cutoff ||
            block.timestamp - tick.committedAt > acct.config().maxTickAge ||
            block.timestamp - tick.referenceTime > $.epochConfig.maxClearingDelay
        ) revert IEpochVault.TickNotUsable();
    }

    function _consumeInstant(EpochVaultStorage.Layout storage $, uint256 assets, uint256 capacity) private {
        uint256 level = uint256($.instantLevel) + (block.timestamp - $.instantUpdatedAt).mulDiv(capacity, 1 days);
        if (level > capacity) level = capacity;
        if (assets > level) revert IEpochVault.LimitExceeded();
        $.instantLevel = uint128(level - assets);
        $.instantUpdatedAt = uint64(block.timestamp);
    }

    function _newRequest(
        EpochVaultStorage.Layout storage $,
        address owner,
        address receiver,
        uint64 epochId,
        IEpochVault.RequestKind kind,
        uint256 amount
    ) private returns (uint256 requestId) {
        requestId = $.nextRequestId++;
        IEpochVault.Request storage r = $.requests[requestId];
        r.owner = owner;
        r.receiver = receiver;
        r.epoch = epochId;
        r.kind = kind;
        r.status = IEpochVault.RequestStatus.Requested;
        r.amount = amount.toUint128();
    }

    function _pullExact(EpochVaultStorage.Layout storage $, address from, uint256 assets) private {
        IERC20Metadata asset_ = $.asset;
        uint256 before = asset_.balanceOf(address(this));
        // `from` is never attacker-chosen: every caller passes either _msgSender()
        // (a request) or the hub agent (returnFunds, which checks it). The measured
        // balance delta below is what actually guards the amount.
        // slither-disable-next-line arbitrary-send-erc20
        asset_.safeTransferFrom(from, address(this), assets);
        if (asset_.balanceOf(address(this)) - before != assets) {
            revert IEpochVault.UnexpectedTokenAmount();
        }
    }

    function _freeCash(EpochVaultStorage.Layout storage $) private view returns (uint256) {
        return $.cash - $.pendingDeposits - $.reserved;
    }

    /// @dev Free cash not already owed to a cleared, unfunded redemption.
    function _availableCash(EpochVaultStorage.Layout storage $) private view returns (uint256) {
        uint256 free = _freeCash($);
        uint256 owed = $.liabilities - $.reserved;
        return free > owed ? free - owed : 0;
    }

    /// @dev max(minimumBuffer, minBufferRatio * latest accepted bid NAV).
    function _minimumBuffer(EpochVaultStorage.Layout storage $) private view returns (uint256) {
        (, ITickAccountant.Tick memory tick) = $.accountant.latestAccepted();
        uint256 ratioBuffer = uint256(tick.navBid).mulDiv($.limits.minBufferRatio, WAD);
        return Math.max($.limits.minimumBuffer, ratioBuffer);
    }

    function _checkpoint(EpochVaultStorage.Layout storage $, uint256 supply) private {
        IEpochVaultAccounting.Checkpoint memory cp = IEpochVaultAccounting.Checkpoint({
            blockNumber: uint64(block.number),
            cash: $.cash.toUint128(),
            pendingDeposits: $.pendingDeposits.toUint128(),
            liabilities: $.liabilities.toUint128(),
            totalSupply: supply.toUint128()
        });
        uint256 n = $.checkpoints.length;
        if (n != 0 && $.checkpoints[n - 1].blockNumber == block.number) {
            $.checkpoints[n - 1] = cp;
        } else {
            $.checkpoints.push(cp);
        }
    }
}
