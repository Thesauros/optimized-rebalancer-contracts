// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IEpochVault
 * @notice Asynchronous hub vault: requests are cleared in epochs at forward
 *         prices taken from committed Ticks.
 */
interface IEpochVault {
    error InvalidInput();
    error InvalidConfig();
    error DomainPaused(uint8 domain);
    error EpochNotClosable();
    error NothingToClear();
    error TickNotUsable();
    error NotRequestOwner();
    error RequestNotCancellable();
    error RequestNotClaimable();
    error InsufficientFreeCash();
    error LimitExceeded();
    error SlippageExceeded();
    error UnexpectedTokenAmount();
    error NotAccountant();
    error NotHubAgent();

    enum RequestKind {
        Deposit,
        Redeem
    }

    enum RequestStatus {
        None,
        Requested,
        Cancelled,
        Claimed
    }

    struct Request {
        address owner;
        address receiver;
        uint64 epoch;
        RequestKind kind;
        RequestStatus status;
        uint128 amount;
    }

    struct Epoch {
        uint64 openedAt;
        uint64 closedAt;
        uint64 openTickId;
        uint64 depositTickId;
        uint64 redeemTickId;
        bool depositsCleared;
        bool redeemsCleared;
        bool funded;
        uint128 openRateBid;
        uint128 depositAssets;
        uint128 redeemShares;
        uint128 rateOffer;
        uint128 priceRedeem;
        uint128 sharesMinted;
        uint128 assetsOwed;
    }

    struct EpochConfig {
        uint64 minDuration;
        uint64 maxDuration;
        uint64 minTicks;
        uint64 maxClearingDelay;
    }

    struct Limits {
        uint128 minDeposit;
        uint128 maxEpochDeposits;
        uint128 minimumBuffer;
        uint128 minBufferRatio;
        uint128 maxInstantWithdrawal;
        uint128 dailyInstantLimit;
        uint64 instantFee;
        uint64 instantMaxTickAge;
    }

    event DepositRequested(uint256 indexed requestId, uint64 indexed epoch, address indexed owner, address receiver, uint256 assets);
    event RedeemRequested(uint256 indexed requestId, uint64 indexed epoch, address indexed owner, address receiver, uint256 shares);
    event RequestCancelled(uint256 indexed requestId);
    event DepositClaimed(uint256 indexed requestId, address indexed receiver, uint256 shares);
    event RedeemClaimed(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event EpochClosed(uint64 indexed epoch, uint64 closedAt);
    event EpochOpened(uint64 indexed epoch, uint64 openTickId, uint256 openRateBid);
    event DepositsCleared(uint64 indexed epoch, uint64 indexed tickId, uint256 assets, uint256 rateOffer, uint256 sharesMinted);
    event RedeemsCleared(uint64 indexed epoch, uint64 indexed tickId, uint256 shares, uint256 priceRedeem, uint256 assetsOwed);
    event EpochFunded(uint64 indexed epoch, uint256 assets);
    event InstantRedeemed(address indexed owner, address indexed receiver, uint64 indexed tickId, uint256 shares, uint256 assets);
    event PushedToAgent(address indexed agent, uint256 assets);
    event ReturnedFromAgent(address indexed agent, uint256 assets);
    event FeeSharesMinted(address indexed to, uint256 shares);
    event PauseSet(uint8 indexed domain, bool paused, address indexed by);
    event EpochConfigUpdated(EpochConfig config);
    event LimitsUpdated(Limits limits);
    event HubAgentUpdated(address indexed agent);
    event TimelockUpdated(address indexed timelock);
}
