/**
 * Minimal human-readable ABIs for the cross-chain contracts, so the ops
 * services run without compile artifacts. Kept in sync with contracts/ by
 * ops/test/abi.test.ts, which compares every signature to the artifact ABIs.
 */

const SNAPSHOT =
  'tuple(uint16 version,uint64 tickId,uint64 referenceTime,' +
  'tuple(uint64 chainId,uint64 blockNumber,bytes32 blockHash)[] chains,' +
  'tuple(uint64 chainId,address holder,address strategy,uint8 kind,uint256 units,uint256 valueBid,uint256 valueOffer)[] positions,' +
  'tuple(bytes32 transferId,uint64 srcChainId,uint64 dstChainId,uint64 sentAt,uint256 amountSent,uint256 minReceive,uint256 writtenDown)[] inFlight,' +
  'uint256 hubCash,uint256 pendingDeposits,uint256 liabilities,uint256 totalShares)';

export const SNAPSHOT_TUPLE = SNAPSHOT;

const TICK =
  'tuple(uint64 referenceTime,uint64 committedAt,uint64 hubBlock,uint8 status,uint8 flags,uint128 rateBid,uint128 rateOffer,uint128 navBid,uint128 navOffer,bytes32 navHash)';

export const ACCESS = [
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function getTimelock() view returns (address)',
  'event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)',
  'event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)',
];

export const TICK_ACCOUNTANT = [
  ...ACCESS,
  `function commitTick(${SNAPSHOT} snapshot, uint256 hubCheckpointIndex)`,
  'function lastTickId() view returns (uint64)',
  'function lastAcceptedTickId() view returns (uint64)',
  `function getTick(uint64 tickId) view returns (${TICK})`,
  `function latestAccepted() view returns (uint64 tickId, ${TICK} tick)`,
  'function frozen() view returns (bool)',
  'function quarantined() view returns (bool)',
  'function config() view returns (tuple(uint64 minTickInterval,uint64 maxSnapshotAge,uint64 maxTickAge,uint64 maxTransit,uint128 maxSpread,uint128 depositClearingMaxDown,uint128 maxInFlightRatio,uint128 maxOverdueInFlight))',
  'function buckets() view returns (tuple(uint128 capacity,uint128 refillPerSecond,uint128 level,uint64 updatedAt) up, tuple(uint128 capacity,uint128 refillPerSecond,uint128 level,uint64 updatedAt) down)',
  'function chainIds() view returns (uint64[])',
  'function isAgent(uint64 chainId, address agent) view returns (bool)',
  'event AgentUpdated(uint64 indexed chainId, address indexed agent, bool allowed)',
  'function vault() view returns (address)',
  'function getFees() view returns (uint96 managementFee, uint96 performanceFee, uint256 highWaterMark, address treasury)',
  'function bridgeSendsAllowed() view returns (bool)',
  'function chainSendAllowed(uint64 dstChainId) view returns (bool)',
  'function maxChainExposure() view returns (uint128)',
  'function isChainOverExposed(uint64 chainId) view returns (bool)',
  'event TickCommitted(uint64 indexed tickId, uint8 status, uint8 flags, uint64 referenceTime, uint64 hubBlock, uint256 rateBid, uint256 rateOffer, uint256 navBid, uint256 navOffer, bytes32 navHash)',
  'event FeesAccrued(uint64 indexed tickId, uint256 managementFeeAssets, uint256 performanceFeeAssets, uint256 feeShares)',
  'event TickRatified(uint64 indexed tickId, address indexed by)',
  'event FrozenSet(bool frozen, address indexed by)',
];

const EPOCH =
  'tuple(uint64 openedAt,uint64 closedAt,uint64 openTickId,uint64 depositTickId,uint64 redeemTickId,bool depositsCleared,bool redeemsCleared,bool funded,uint128 openRateBid,uint128 depositAssets,uint128 redeemShares,uint128 rateOffer,uint128 priceRedeem,uint128 sharesMinted,uint128 assetsOwed,uint128 redeemSharesClaimed,uint128 assetsPaid)';

export const EPOCH_VAULT = [
  ...ACCESS,
  'function asset() view returns (address)',
  'function symbol() view returns (string)',
  'function accountant() view returns (address)',
  'function hubAgent() view returns (address)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function accounting() view returns (uint256 cash, uint256 pendingDeposits, uint256 liabilities, uint256 reserved, uint256 escrowRedeemShares, uint256 unclaimedDepositShares)',
  'function checkpointCount() view returns (uint256)',
  'function checkpointAt(uint256 index) view returns (tuple(uint64 blockNumber,uint128 cash,uint128 pendingDeposits,uint128 liabilities,uint128 totalSupply))',
  'function currentEpoch() view returns (uint64)',
  `function getEpoch(uint64 epochId) view returns (${EPOCH})`,
  'function getRequest(uint256 requestId) view returns (tuple(address owner,address receiver,uint64 epoch,uint8 kind,uint8 status,uint128 amount))',
  'function cursors() view returns (uint64 nextDepositClear, uint64 nextRedeemClear, uint64 nextFund)',
  'function epochConfig() view returns (tuple(uint64 minDuration,uint64 maxDuration,uint64 minTicks,uint64 maxClearingDelay))',
  'function limits() view returns (tuple(uint128 minDeposit,uint128 maxEpochDeposits,uint128 minimumBuffer,uint128 minBufferRatio,uint128 maxInstantWithdrawal,uint128 dailyInstantLimit,uint64 instantFee,uint64 instantMaxTickAge))',
  'function paused(uint8 domain) view returns (bool)',
  'function freeCash() view returns (uint256)',
  'function minimumBuffer() view returns (uint256)',
  'function closeEpoch()',
  'function clearDeposits()',
  'function clearRedeems()',
  'function fund()',
  'function claim(uint256 requestId) returns (uint256)',
  'function requestDeposit(uint256 assets, address receiver) returns (uint256)',
  'function requestRedeem(uint256 shares, address receiver, address owner) returns (uint256)',
  'function pushToAgent(uint256 assets)',
  'function instantRedeem(uint256 shares, address receiver, address owner, uint256 minAssets) returns (uint256)',
  'function cancel(uint256 requestId)',
  'event DepositRequested(uint256 indexed requestId, uint64 indexed epoch, address indexed owner, address receiver, uint256 assets)',
  'event RedeemRequested(uint256 indexed requestId, uint64 indexed epoch, address indexed owner, address receiver, uint256 shares)',
  'event EpochClosed(uint64 indexed epoch, uint64 closedAt)',
];

export const CHAIN_AGENT = [
  ...ACCESS,
  'function asset() view returns (address)',
  'function strategy() view returns (address)',
  'function vault() view returns (address)',
  'function idle() view returns (uint256)',
  'function strategyShares() view returns (uint256)',
  'function getRoute(bytes32 routeId) view returns (tuple(address adapter,uint64 dstChainId,address dstAgent,uint16 maxFeeBps,bool enabled,uint128 maxPerTransfer,uint128 capacity,uint128 refillPerSecond,uint128 level,uint64 updatedAt))',
  'function getSent(bytes32 transferId) view returns (tuple(bytes32 routeId,uint64 dstChainId,uint64 sentAt,uint128 amount,uint128 minReceive,uint128 writtenDown))',
  'function getReceived(bytes32 transferId) view returns (tuple(uint64 srcChainId,uint64 receivedAt,uint128 amount))',
  'function isPeer(uint64 chainId, address agent) view returns (bool)',
  'function isAdapter(address adapter) view returns (bool)',
  'function paused(uint8 domain) view returns (bool)',
  'function receiveBridge(address adapter, bytes payload) returns (bytes32 transferId, uint256 amount)',
  'function allocate(uint256 assets) returns (uint256)',
  'function deallocate(uint256 assets) returns (uint256)',
  'function deallocateShares(uint256 shares, uint256 minAssets) returns (uint256)',
  'function returnToVault(uint256 assets)',
  'function bridgeOut(bytes32 routeId, uint256 amount, uint256 minReceive, bytes32 rebalanceId) payable returns (bytes32)',
  'event BridgeOut(bytes32 indexed transferId, bytes32 indexed rebalanceId, bytes32 indexed routeId, uint64 dstChainId, address dstAgent, uint256 amount, uint256 minReceive)',
  'event BridgeIn(bytes32 indexed transferId, uint64 indexed srcChainId, address indexed srcAgent, uint256 amount)',
  'event WrittenDown(bytes32 indexed transferId, uint256 amount, uint256 totalWrittenDown, bytes32 reason)',
];

export const STRATEGY = [
  ...ACCESS,
  'function asset() view returns (address)',
  'function totalAssets() view returns (uint256)',
  'function convertToAssets(uint256 shares) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function providersHealthy() view returns (bool)',
  'function getProviders() view returns (address[])',
  'function getEntryProvider() view returns (address)',
  'function getProviderCap(address provider) view returns (uint256)',
  'function paused(uint8 action) view returns (bool)',
];

export const PROVIDER = ['function getDepositBalance(address user, address vault) view returns (uint256)', 'function getIdentifier() view returns (string)'];

export const ADAPTER = [
  'function remotes(uint64 chainId) view returns (uint32 domain, address adapter, bool set)',
  'function governance() view returns (address)',
  'function agent() view returns (address)',
];

export const TIMELOCK = [
  'function owner() view returns (address)',
  'function delay() view returns (uint256)',
  'event Queued(bytes32 indexed txId, address indexed target, uint256 value, string signature, bytes data, uint256 timestamp)',
  'event Executed(bytes32 indexed txId, address indexed target, uint256 value, string signature, bytes data, uint256 timestamp)',
  'event Cancelled(bytes32 indexed txId, address indexed target, uint256 value, string signature, bytes data, uint256 timestamp)',
];

export const OWNABLE = ['function owner() view returns (address)', 'function pendingOwner() view returns (address)'];

export const ERC20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function decimals() view returns (uint8)'];

export const ADMIN_ROLE = '0x' + '00'.repeat(32);
