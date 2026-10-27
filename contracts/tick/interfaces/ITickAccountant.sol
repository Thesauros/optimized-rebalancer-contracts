// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {NavSnapshot} from "../NavSnapshot.sol";

/**
 * @title ITickAccountant
 * @notice Discrete, append-only record of committed NAV states (Ticks).
 */
interface ITickAccountant {
    error InvalidTickId();
    error InvalidTime();
    error TooSoon();
    error ChainSetMismatch();
    error UnknownAgent();
    error UnknownChain();
    error InvalidHubReference();
    error HubStateMismatch();
    error ZeroShares();
    error InvalidConfig();
    error NotQuarantined();
    error VaultAlreadySet();

    enum TickStatus {
        None,
        Accepted,
        Quarantined,
        Ratified
    }

    /// @notice Stored per Tick; never rewritten except Quarantined -> Ratified.
    /// @dev Rates are asset units per share scaled by 1e18, net of fees for
    ///      Accepted Ticks and gross for Quarantined/Ratified ones.
    struct Tick {
        uint64 referenceTime;
        uint64 committedAt;
        uint64 hubBlock;
        TickStatus status;
        uint8 flags;
        uint128 rateBid;
        uint128 rateOffer;
        uint128 navBid;
        uint128 navOffer;
        bytes32 navHash;
    }

    struct Config {
        uint64 minTickInterval;
        uint64 maxSnapshotAge;
        uint64 maxTickAge;
        uint64 maxTransit;
        uint128 maxSpread;
        uint128 depositClearingMaxDown;
        uint128 maxInFlightRatio;
        uint128 maxOverdueInFlight;
    }

    /// @notice Rate-movement allowance, as a 1e18-scaled fraction of the previous rate.
    struct Bucket {
        uint128 capacity;
        uint128 refillPerSecond;
        uint128 level;
        uint64 updatedAt;
    }

    event TickCommitted(
        uint64 indexed tickId,
        TickStatus status,
        uint8 flags,
        uint64 referenceTime,
        uint64 hubBlock,
        uint256 rateBid,
        uint256 rateOffer,
        uint256 navBid,
        uint256 navOffer,
        bytes32 navHash
    );
    event TickRatified(uint64 indexed tickId, address indexed by);
    event FeesAccrued(
        uint64 indexed tickId,
        uint256 managementFeeAssets,
        uint256 performanceFeeAssets,
        uint256 feeShares
    );
    event FrozenSet(bool frozen, address indexed by);
    event ConfigUpdated(Config config);
    event BucketsUpdated(Bucket up, Bucket down);
    event MaxChainExposureUpdated(uint128 ratio);
    event ChainsUpdated(uint64[] chainIds);
    event AgentUpdated(uint64 indexed chainId, address indexed agent, bool allowed);
    event FeesUpdated(uint96 managementFee, uint96 performanceFee);
    event TreasuryUpdated(address indexed treasury);
    event VaultSet(address indexed vault);
    event TimelockUpdated(address indexed timelock);

    function commitTick(
        NavSnapshot.Snapshot calldata snapshot,
        uint256 hubCheckpointIndex
    ) external;

    function lastTickId() external view returns (uint64);

    function lastAcceptedTickId() external view returns (uint64);

    function getTick(uint64 tickId) external view returns (Tick memory);

    function latestAccepted() external view returns (uint64 tickId, Tick memory tick);

    function frozen() external view returns (bool);

    function config() external view returns (Config memory);

    function bridgeSendsAllowed() external view returns (bool);

    /// @notice `bridgeSendsAllowed`, narrowed to one destination chain so that a
    ///         chain above its exposure cap stops receiving but can still send.
    function chainSendAllowed(uint64 dstChainId) external view returns (bool);
}
