# Reproducing a Thesauros Tick

This is the procedure for an independent partner to recompute any committed Tick
and arrive at the same snapshot, the same derived rates and the same `navHash`.
It uses only public chain data and the rules below.

Contracts: `TickAccountant` (hub, Base), `EpochVault` (hub), and one `ChainAgent`
per chain. The encoding is defined in `contracts/tick/NavSnapshot.sol`.

## 1. What is on-chain for every Tick

| Where | What |
|---|---|
| `TickAccountant.commitTick(snapshot, hubCheckpointIndex)` transaction input | The **full snapshot**, as ABI-encoded calldata |
| `TickCommitted` event | tickId, status (Accepted / Quarantined), flags, referenceTime, hub block, rateBid, rateOffer, navBid, navOffer, navHash |
| `FeesAccrued` event | Management and performance fee assets, and the fee shares minted |
| `TickAccountant.getTick(id)` | The stored header (append-only) |

Because the snapshot is calldata, a partner does not need to trust any
off-chain publication. The work is to confirm that **every field in that
calldata equals what the chains said at the referenced blocks**, and that no
Thesauros holding is missing from it.

## 2. Step by step

### Step 1. Fetch and decode

Take the `commitTick` transaction for `tickId`. Decode the calldata as
`(NavSnapshot.Snapshot, uint256)`. Check that `keccak256(abi.encode(snapshot))`
equals the `navHash` in the event. The contract already enforces this, but
checking it makes the rest of the procedure self-contained.

### Step 2. Reference blocks: the consistent cut

`snapshot.referenceTime = T`. For each chain in `snapshot.chains`, which is the
configured set in strictly ascending chainId, verify the following:

1. `blockNumber` is a canonical block and `blockHash` matches it.
2. **Cut rule.** Start from the last block with `timestamp ≤ T` on each chain.
3. For every `BridgeIn(transferId)` emitted by a destination agent at or before
   its reference block, the matching `BridgeOut(transferId)` on the source agent
   must be at or before the source reference block. Where it is not, the source
   reference block is advanced to the block containing that `BridgeOut`.
4. Repeat step 3 until nothing changes. The process only moves blocks forward and
   is bounded by the chain heads, so it terminates, and the result is unique for
   a given `T`.
5. The chain references in the snapshot must equal this fixpoint.

Reference blocks should be **finalized**: the Ethereum finalized checkpoint, and
the L2 safe/finalized head. The hub reference block is also checked on-chain:
it must be within 256 blocks of the commit and match `blockhash`.

### Step 3. The agent set

`TickAccountant.isAgent(chainId, agent)` and the `AgentUpdated` events give the
registered agents per chain. Every registered agent with a non-zero holding at
its reference block **must** appear in `positions`. Every position's holder
must be registered; the contract enforces that direction.

### Step 4. Positions

For each agent, at its chain's reference block:

| kind | `strategy` | `units` | `valueBid` = `valueOffer` |
|---|---|---|---|
| `IDLE` (0) | `address(0)` | `asset.balanceOf(agent)` | `units` |
| `STRATEGY_SHARES` (1) | `agent.strategy()` | `IERC20(strategy).balanceOf(agent)` | `Rebalancer(strategy).convertToAssets(units)` |

**Ordering** is strictly ascending by `(chainId, holder, strategy, kind)`. An
agent's idle entry therefore precedes its strategy entry. Zero holdings are
omitted.

**What `convertToAssets` contains**, per protocol. These are the only protocols
this repository integrates:

| Protocol | Adapter | Value read | Accrued yield | Debt | Rewards |
|---|---|---|---|---|---|
| Aave V3 | `AaveV3Provider.getDepositBalance` | `aToken.balanceOf(strategy)` for the strategy's asset; pool from `PoolAddressesProvider.getPool()` | Included (aToken balances rebase) | None. Thesauros only supplies | Not recognized |
| Compound V3 | `CompoundV3Provider.getDepositBalance` | `comet.balanceOf(strategy)`; Comet from `ProviderManager.getYieldToken("Compound_V3_Provider", asset)` | Included (present-value balance) | None | COMP not recognized |
| Morpho (MetaMorpho) | `MorphoProvider.getDepositBalance` | `shares · min(realAssets, bookAssets) / (totalSupply + pendingFeeShares)` | Included; pending curator fee deducted | Unrealized bad debt excluded via `min(real, book)` | Not recognized |

The strategy then sums the provider balances into `totalAssets()`. It converts
the agent's shares at `totalAssets / (totalSupply + its own pending fee shares)`,
rounding down (`Rebalancer._convertToAssets`). A partner may recompute that sum
provider by provider as a cross-check. The number that goes into the snapshot is
the `convertToAssets` result itself.

**Unhealthy strategy.** If `Rebalancer(strategy).providersHealthy()` is false at
the reference block, one provider's balance view failed and `convertToAssets`
under-states the position. Then:

* `valueBid` is still the `convertToAssets` result, which is safe for exits;
* `valueOffer` is `max(valueBid, the same position's valueOffer in the previous
  accepted Tick)`.

This keeps entries from being priced against an incomplete NAV.

**Rewards** of any kind are recognized only after they have been swapped into
the vault asset and are held as idle. The same rule applies on both sides (bid
and offer).

### Step 5. In flight

For every `BridgeOut(transferId, …)` emitted by a source agent at or before its
reference block, check whether a `BridgeIn(transferId)` was emitted by the
destination agent at or before its reference block.

* If it was, the funds are already in the destination's idle balance, so there
  is no entry.
* If it was not, add one entry. The fields come from the source agent's
  `getSent(transferId)` at the source reference block:

| Field | Source |
|---|---|
| `transferId`, `srcChainId`, `dstChainId`, `sentAt`, `amountSent`, `minReceive` | the `Sent` record |
| `writtenDown` | the `Sent` record (reflects `WrittenDown` events up to that block) |

**Ordering** is strictly ascending by `transferId`. Valuation is done by the
contract:

* **offer** = `amountSent − writtenDown`
* **bid** = `min(minReceive, offer)`
* **overdue** means `T − sentAt > maxTransit`; it sets a flag but does not change
  the value.

### Step 6. Hub fields

At the hub reference block, read `EpochVault.checkpointAt(i)` for the
checkpoint in force (the last one with `blockNumber ≤` the hub block). Then
check these equalities:

| Snapshot field | Checkpoint field | Definition |
|---|---|---|
| `hubCash` | `cash` | Accounted vault cash; donations are ignored |
| `pendingDeposits` | `pendingDeposits` | Uncleared deposit cash: excluded from NAV |
| `liabilities` | `liabilities` | Cleared, unpaid redemptions: subtracted |
| `totalShares` | `totalSupply` | Includes escrowed redemption shares and unclaimed deposit shares |

The contract enforces all four equalities. They are listed so a partner can
see why hub-side misreporting is impossible.

### Step 7. Derive, then compare with the event

```
navBid   = hubCash + Σ positions.valueBid   + Σ inFlight.bid   − pendingDeposits − liabilities
navOffer = hubCash + Σ positions.valueOffer + Σ inFlight.offer − pendingDeposits − liabilities
grossBid   = floor(navBid   · 1e18 / totalShares)
grossOffer = floor(navOffer · 1e18 / totalShares)
```

* **Accepted Tick.** Apply the fees from the `FeesAccrued` event:
  `rateBid = floor(grossBid · (navBid − fee) / navBid)`, and the same for offer.
  The fee itself is recomputable:
  * management fee = `navBid · managementFee · dt / (365 days · 1e18)`, where `dt`
    runs from the previous fee accrual;
  * performance fee = `(rateAfterMgmt − HWM) · totalShares / 1e18 · performanceFee / 1e18`,
    only if the rate is above the high-water mark;
  * the fee parameters and HWM come from `getFees()` at the block before the commit.
* **Quarantined or Ratified Tick.** The event carries the gross rates, and no fee
  is charged.

Every derived number must equal the `TickCommitted` event.

## 3. What a partner can and cannot detect

| Divergence | Detected by |
|---|---|
| A position value differs from `convertToAssets` / `balanceOf` at the block | Step 4 |
| A holding is missing (omitted agent, omitted strategy shares) | Step 3–4 |
| An in-flight entry is missing, invented, or double-counted with a receipt | Step 5 + cut rule |
| Wrong reference block or hash | Step 2 |
| Hub cash / pending / liabilities / shares misreported | Impossible (on-chain check) |
| Arithmetic or encoding inconsistent with fields | Impossible (on-chain check) |

A divergence found by a partner is an **updater fault**. Its economic effect is
bounded by the rate buckets and quarantine in any case
(`docs/tick-accounting-design.md` §6).

## 4. Reference implementation

`test/tick/TickFixture.sol::_buildSnapshot` implements steps 3–6 for the
single-EVM test topology, and every honest commit in the test suite goes
through it. A production builder is a TypeScript service. It needs:

* RPC access to every chain at the chosen blocks, with at least two independent
  providers, which must agree;
* event scans of `BridgeOut`, `BridgeIn` and `WrittenDown` per agent;
* the cut fixpoint of step 2;
* ABI encoding with ethers `AbiCoder` of the `NavSnapshot.Snapshot` tuple.

It is listed as remaining work in `docs/implementation-report.md`.
