// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title NavSnapshot
 * @notice Canonical NAV snapshot types, encoding and arithmetic.
 * @dev The snapshot is ABI-encoded (never JSON) and hashed as
 *      `keccak256(abi.encode(snapshot))`. Every array is strictly ordered, so a
 *      given economic state has exactly one encoding. Rates and NAV totals are
 *      not fields: they are derived here from the fields, so a snapshot cannot
 *      carry a rate that contradicts its own positions.
 *      See docs/tick-accounting-design.md §4 and docs/nav-reproduction.md.
 */
library NavSnapshot {
    uint16 internal constant VERSION = 1;

    uint8 internal constant KIND_IDLE = 0;
    uint8 internal constant KIND_STRATEGY_SHARES = 1;

    error UnsupportedVersion();
    error UnsortedChains();
    error UnsortedPositions();
    error UnsortedInFlight();
    error UnknownKind();
    error InvalidValue();

    /// @notice Reference block of one chain, chosen by the consistent-cut rule.
    struct ChainRef {
        uint64 chainId;
        uint64 blockNumber;
        bytes32 blockHash;
    }

    /// @notice One holding of one Thesauros agent on one chain.
    /// @param units Strategy shares (KIND_STRATEGY_SHARES) or asset units (KIND_IDLE).
    struct Position {
        uint64 chainId;
        address holder;
        address strategy;
        uint8 kind;
        uint256 units;
        uint256 valueBid;
        uint256 valueOffer;
    }

    /// @notice A transfer sent inside the cut and not received inside it.
    struct InFlight {
        bytes32 transferId;
        uint64 srcChainId;
        uint64 dstChainId;
        uint64 sentAt;
        uint256 amountSent;
        uint256 minReceive;
        uint256 writtenDown;
    }

    struct Snapshot {
        uint16 version;
        uint64 tickId;
        uint64 referenceTime;
        ChainRef[] chains;
        Position[] positions;
        InFlight[] inFlight;
        uint256 hubCash;
        uint256 pendingDeposits;
        uint256 liabilities;
        uint256 totalShares;
    }

    /// @notice Figures derived from a snapshot.
    struct Totals {
        uint256 navBid;
        uint256 navOffer;
        uint256 inFlight;
        uint256 overdueInFlight;
    }

    function hash(Snapshot calldata s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /**
     * @notice Checks the version and strict ordering of every array.
     * @dev Strict ordering also rejects duplicates.
     */
    function validateEncoding(Snapshot calldata s) internal pure {
        if (s.version != VERSION) revert UnsupportedVersion();

        for (uint256 i = 1; i < s.chains.length; i++) {
            if (s.chains[i].chainId <= s.chains[i - 1].chainId) {
                revert UnsortedChains();
            }
        }

        for (uint256 i; i < s.positions.length; i++) {
            Position calldata p = s.positions[i];
            if (p.kind > KIND_STRATEGY_SHARES) revert UnknownKind();
            if (p.valueOffer < p.valueBid) revert InvalidValue();
            if (i > 0 && !_positionAfter(p, s.positions[i - 1])) {
                revert UnsortedPositions();
            }
        }

        for (uint256 i; i < s.inFlight.length; i++) {
            InFlight calldata f = s.inFlight[i];
            if (f.minReceive > f.amountSent || f.writtenDown > f.amountSent) {
                revert InvalidValue();
            }
            if (
                i > 0 &&
                uint256(f.transferId) <= uint256(s.inFlight[i - 1].transferId)
            ) revert UnsortedInFlight();
        }
    }

    /**
     * @notice Derives bid/offer NAV and in-flight risk figures.
     * @dev In flight: bid = min(minReceive, sent - writtenDown),
     *      offer = sent - writtenDown. Overdue = older than `maxTransit` at the
     *      snapshot's reference time. Pending deposits are not NAV; cleared,
     *      unpaid withdrawals are a liability. Reverts if liabilities exceed assets.
     */
    function totals(
        Snapshot calldata s,
        uint256 maxTransit
    ) internal pure returns (Totals memory t) {
        uint256 assetsBid = s.hubCash;
        uint256 assetsOffer = s.hubCash;

        for (uint256 i; i < s.positions.length; i++) {
            assetsBid += s.positions[i].valueBid;
            assetsOffer += s.positions[i].valueOffer;
        }

        for (uint256 i; i < s.inFlight.length; i++) {
            InFlight calldata f = s.inFlight[i];
            uint256 offer = f.amountSent - f.writtenDown;
            uint256 bid = f.minReceive < offer ? f.minReceive : offer;
            assetsBid += bid;
            assetsOffer += offer;
            t.inFlight += offer;
            if (
                s.referenceTime > f.sentAt &&
                s.referenceTime - f.sentAt > maxTransit
            ) {
                t.overdueInFlight += offer;
            }
        }

        uint256 deductions = s.pendingDeposits + s.liabilities;
        if (assetsBid < deductions) revert InvalidValue();
        t.navBid = assetsBid - deductions;
        t.navOffer = assetsOffer - deductions;
    }

    function _positionAfter(
        Position calldata p,
        Position calldata prev
    ) private pure returns (bool) {
        if (p.chainId != prev.chainId) return p.chainId > prev.chainId;
        if (p.holder != prev.holder) return p.holder > prev.holder;
        if (p.strategy != prev.strategy) return p.strategy > prev.strategy;
        return p.kind > prev.kind;
    }
}
