# Epoch and Tick frequency benchmark

Most values here are a **configuration**, not a constant:

* `TickAccountant.Config` and buckets, set with `setConfig` and `setBuckets`
  (`maxChainExposure` has its own setter, `setMaxChainExposure`);
* `EpochVault.EpochConfig` and `Limits`, set with `setEpochConfig` and `setLimits`.

All of them change through the Timelock, with no contract replacement.

**Not everything is configurable.** A set of compiled constants bounds what any
configuration can express — the 256-block `blockhash` window that caps
`maxSnapshotAge`, `MAX_FUND_ITERATIONS`, `DEPOSIT_BLOCKING_FLAGS`, the 1-day
instant-exit window, `PROVIDER_VIEW_CALL_GAS` and `Timelock.MIN_DELAY`. They are
listed with their code references in §6, and three configured values are
*derived* from them in `registry.ts` rather than chosen freely (§5.1).

This document records what was measured, what the measurements imply, and what is
still unmeasured.

## 1. Why epoch length is no longer the stale-NAV lever

Queued requests are **forward-priced** at a Tick observed after the epoch
cutoff. Knowing an upcoming Tick therefore gives no edge whatever the epoch
length (tested: `AdversarialScenarios.t.sol::testDepositAroundPositiveTickIsNotProfitable`).

Epoch length trades only:

* **UX latency:** a deposit or redemption waits until the cutoff, then for the
  next accepted Tick.
* **Netting:** longer epochs net more deposits against redemptions and need
  fewer bridge legs.
* **Settlement gas and operations:** one `closeEpoch`, one of each clear, and
  one claim per user.
* **Yield forgone while queued:** redemptions pay `min(open, clear)`, so
  roughly epoch × APR is forgone.

The one remaining backward-priced path, the instant exit, is governed by its
own limits, not by epoch length.

## 2. Measured gas

Reproduce with exactly this command:

```
forge test --gas-report --match-path 'test/tick/*.t.sol' \
  --no-match-path 'test/tick/CrossChainInvariants.t.sol'
```

`test/tick/*` is fork-free, but `CrossChainInvariants.t.sol` must be excluded:
its handler calls the same entry points 500 times per run for 256 runs, so it
dominates every aggregate and shifts the medians away from a single-call cost.
The command above runs 83 tests in about 1 s. solc 0.8.33, optimizer 200 runs,
re-measured 2026-09-28 after the `maxChainExposure`, `chainBids`,
`deallocateShares` and cancel-rule changes. The fixture has 2 chains, up to 4
positions and a few in-flight entries.

| Call | Median gas | Max gas | Frequency |
|---|---|---|---|
| `TickAccountant.commitTick` | 197,810 | 308,260 (with fee mint) | per Tick |
| `EpochVault.closeEpoch` | 94,986 | 94,986 | per epoch |
| `EpochVault.clearDeposits` | 216,500 | 216,500 | per epoch |
| `EpochVault.clearRedeems` | 56,365 (empty) | 258,789 | per epoch |
| `EpochVault.requestDeposit` | 204,050 | 245,858 | per user action (includes checkpoint write) |
| `EpochVault.requestRedeem` | 145,949 | 145,949 | per user action |
| `EpochVault.cancel` (deposit refund) | 56,881 | 155,095 | per user action |
| `EpochVault.claim` | 60,132 | 94,097 | per user action |
| `EpochVault.instantRedeem` | 117,022 | 173,135 | per user action |
| `ChainAgent.bridgeOut` (mock adapter) | 378,835 | 378,835 | per bridge leg |
| `ChainAgent.receiveBridge` (mock adapter) | 121,006 | 121,006 | per bridge leg |

`commitTick`'s median is the one figure here that does not reproduce to the unit:
the fuzz seed is unpinned, so the mix of accepted, quarantined and fee-minting
commits differs between runs. Treat it as ±5%.

Clearing is O(1) in the number of requests. Per-user work happens in `claim`,
paid by whoever claims.

**Calldata growth.** Each additional position is 7 words (224 bytes) and each
in-flight entry is 7 words. On Base, calldata cost is dominated by the L1 data
fee, not execution gas. A realistic snapshot (3 chains, about 10 positions, a
few transfers) is about 3–4 KB.

**Contract size.** `forge build --sizes`, 2026-09-28. After the split into
`EpochVault` and the linked `EpochVaultLogic` library, the vault is 16,456 B and
the library 12,355 B, with margins of 8,120 B and 12,221 B under EIP-170. The
other deployable contracts: `TickAccountant` 20,299 B (margin 4,277 B),
`Rebalancer` 18,432 B (6,144 B), `ChainAgent` 15,202 B (9,374 B),
`CctpV2Adapter` 4,476 B (20,100 B). `TickAccountant` is the tightest and grew
with `maxChainExposure`, `chainBids` and the explicit `UnknownChain` membership
check; a further ~4 KB of headroom is what any future Tick-side feature has to
fit in. The figures above are after the split.

**Estimate, not a measurement:** the DELEGATECALL into the library is believed to
add about 3–5k gas per entry point against the monolithic version. It was never
measured against the pre-split tree (`f488c4a`), and no conclusion here depends
on it.

## 3. Unmeasured (needs mainnet or fork observation)

| Quantity | Why it matters | How to measure |
|---|---|---|
| CCTP V2 standard and fast latency, Base↔Arbitrum | Sets `maxTransit` and how quickly an epoch can be funded from recalls | Send small canary transfers; timestamp `BridgeOut` against `BridgeIn`. (Base↔Ethereum is listed in the design but no Ethereum agent is deployed — `registry.ts` has two chains) |
| **Finality and reorg depth per chain** — Base and Arbitrum safe/finalized lag, and Ethereum's finalized-checkpoint lag if a third chain is ever added | Decides which head the NAV engine may pin a reference block to, and therefore how old a snapshot can be before it is unsafe rather than merely stale. A reference block taken inside the reorg window can be orphaned, which fails the commit as `InvalidHubReference` on the hub and silently misprices a remote position elsewhere | Read `eth_getBlockByNumber("safe")` / `("finalized")` against the live head over a week; record max observed lag and any reorg that changed a block below it |
| **Rebalance duration** inside one strategy: how long a provider withdrawal takes when a market is at high utilization, and how many legs a reallocation needs | It is the second half of a recall. A bridge round trip plus a slow Aave/Morpho withdrawal is what actually decides whether a recall fits inside one epoch (§7) | Time `deallocate`/`deallocateShares` against live markets at high utilization on a fork; count legs per reallocation from the Rebalance-Engine logs |
| Historic daily flows of the live vaults | Epoch deposit caps, instant daily limit | Index `Deposit`/`Withdraw` events of the live `Rebalancer`s |
| **Yield volatility, not yield forgone:** the distribution of rate moves *inside one epoch*, relative to bucket capacity | Forgone yield is epoch × APR and is roughly linear in cadence; volatility is not. What decides whether a cadence is safe is how far the bid rate can move between epoch open and clearing against `downBucket.capacity` (0.2%) and `upBucket.capacity` (0.5%). A cadence is only as long as its worst intra-epoch move stays inside the buckets, otherwise Ticks quarantine and clearing stalls | Replay `convertToAssets` of the live strategies per hour over 90 days; take the max and the 99.9th percentile of the move over 1 h, 4 h, 6 h, 24 h and per 5/10 Ticks, and compare each with the bucket capacities |
| Max observed daily rate move of the strategy set | Bucket refill and capacity | Same replay as the row above |
| **Operational cost per cadence**: keeper transactions, NAV-engine runs, and the Base L1 data fee per `commitTick` | A 30 min or per-Tick cadence multiplies the fixed cost of running the service, and on Base the L1 data fee, not execution gas, is the dominant part of a 3–4 KB commit (§2) | Count keeper transactions per day per cadence from §4; measure the L1 data fee on the first mainnet commits |
| L1 data fee on Base for a 4 KB commit | Tick cost | Measure on the first testnet or mainnet commits |

## 4. Candidate cadences

Defaults, evaluated against a 1 h operational Tick cadence:

| Cadence | Deposit wait (avg / max) | Clearing txs/day | Netting | Assessment |
|---|---|---|---|---|
| Clear every Tick (1 h Ticks) | ~0.5 h / ~2 h | 24 × 3 | poor | Works. Many near-empty epochs; best UX |
| **6 h epochs, 1 h Ticks** | ~3.5 h / ~7 h | 4 × 3 | good | **Recommended starting point**: recalls fit inside one epoch if CCTP latency proves well under an hour |
| 24 h epochs | ~12.5 h / ~25 h | 1 × 3 | best | Fund-like (T+1); weak DeFi UX |

**Researched variants, not defaults.** The contract supports tick-count epochs
directly: `EpochConfig.minTicks`, with `minDuration` set low enough (≥
`minTickInterval`) that the Tick count is the binding condition and `maxDuration`
acts as the backstop if Ticks stop. `closeEpoch` is
`(elapsed ≥ minDuration ∧ acceptedTicks ≥ minTicks) ∨ elapsed ≥ maxDuration`.

| Cadence | Deposit wait (avg / max) | Clearing txs/day | Netting | Assessment |
|---|---|---|---|---|
| Every 5 Ticks (`minTicks = 5`, 1 h Ticks → ~5 h epochs) | ~3 h / ~6 h | ~4.8 × 3 | good | Closest tick-native equivalent of the 6 h default, but it self-adjusts: if the Tick cadence slows to 2 h the epoch stretches to 10 h instead of clearing on a stale rate. Costs one `maxDuration` backstop that must stay above 5 × the worst acceptable Tick interval, or a Tick outage closes epochs on the time path anyway |
| Every 10 Ticks (`minTicks = 10`, 1 h Ticks → ~10 h epochs) | ~5.5 h / ~11 h | ~2.4 × 3 | better | T+0.5 settlement. Netting and gas improve, UX degrades; the intra-epoch rate move doubles against the 6 h case, so it needs the §3 volatility measurement before it is safe. Same `maxDuration` coupling, twice as tight |
| 30 min epochs | ~0.75 h / ~1.5 h | 48 × 3 | poor | Only coherent with a Tick cadence ≤ 30 min, because clearing needs a Tick whose `referenceTime` is after the cutoff; with 1 h Ticks roughly every other epoch clears on a Tick that is up to an hour old. Doubling the Tick rate doubles the commit cost and the L1 data fee (§8) and halves the intra-epoch move, which is the one axis it improves. `minTickInterval` is 5 min, so nothing in the contract forbids it |

Withdrawal latency is **not** the deposit column and is not proportional to it;
see §7. Operational cost per row is in §8.

## 5. Recommended initial configuration (to be confirmed by §3)

Values are the `production` profile of `deploy/crosschain/registry.ts`, read on
2026-09-28. The `stand` profile differs only where noted.

| Parameter | Value | Reason |
|---|---|---|
| Tick cadence (operational) | 1 h, plus on material events | Transparency. Staleness guard `maxTickAge = 2 h` tolerates one missed Tick |
| `minTickInterval` | 5 min | Bounds commit spam; well under the cadence. Must also cover the confirmation depth (§5.1, relation 4) |
| `maxSnapshotAge` | **8 min** (derived) | Must stay under the 256-block `blockhash` ceiling of 256 × 2 s = 512 s ≈ 8.5 min. 10 min, the earlier value, was unreachable: every commit that old fails `InvalidHubReference`, which does not distinguish "stale" from "reorged". Kept just below the ceiling so a stale snapshot fails as `InvalidTime`, which names the problem (§5.1, relation 1) |
| `maxTickAge` | 2 h | Two missed Ticks |
| `maxTransit` | 1 h | Placeholder until CCTP latency is measured |
| `maxOverdueInFlight` | **0** (both profiles) | Nothing may sit in flight past `maxTransit`: the first overdue unit sets `FLAG_OVERDUE_IN_FLIGHT`, which blocks deposit clearing and hub sends. Never benchmarked — it has only ever been 0, so there is no measurement behind it. Raise it only with a measured CCTP latency distribution, and note that raising it widens the window in which a lost transfer is still valued at `minReceive` |
| `maxInFlightRatio` | 25% of `navBid` (stand: 60%) | Hub sends halt above it |
| `maxChainExposure` | **0 = disabled** | Implemented, off at launch: with two chains all capital starts on the hub, so any cap below 100% is breached on day one and the flag would be permanent noise. Set it through the Timelock once a target allocation exists or a third chain is added |
| `EpochConfig.minDuration / maxDuration` | 4 h / 6 h (stand: 1 h / 2 h) | §4 |
| `EpochConfig.minTicks` | 1 | At least one accepted Tick inside the epoch |
| `EpochConfig.maxClearingDelay` | **2 h 23 min** (derived: `maxTickAge + maxSnapshotAge + 15 min`) | `_usableTick` requires *both* freshness conditions, so a value below the sum makes clearing impossible while the accountant still reports itself healthy (§5.1, relation 2). The 1 h previously recommended violated it against a 2 h `maxTickAge` |
| Up bucket | capacity 0.5%, refill 20% APR | Above any plausible stablecoin lending APR; one delayed-transfer recognition fits |
| Down bucket | capacity 0.2%, refill 0.1%/day | A larger loss needs ADMIN ratification. Also the calibration term for `instantFee` (§5.1, relation 3) |
| `depositClearingMaxDown` | 0.1% | Entries wait on a Tick that moved down more than this |
| `maxSpread` | 1% | Bounded by the in-flight share |
| `minimumBuffer` | 10,000 USDC (stand: 5) | Absolute floor of cash kept in the vault. `pushToAgent` cannot go below it, so it is what keeps instant exits and the first funding leg payable before any recall lands |
| `minBufferRatio` | 5% of bid NAV (stand: 10%) | The effective buffer is `max(minimumBuffer, minBufferRatio · navBid)`, so the ratio takes over as the vault grows and the absolute floor stops being the binding term |
| `minDeposit` / `maxEpochDeposits` | 10 USDC / 5,000,000 USDC | Dust control; bounds what one epoch's mis-pricing can affect |
| Instant exit | per call 10,000, per day 50,000, **fee 0.25%**, `instantMaxTickAge` 2 h | Enabled with limits per the founder decision. The fee is set by relation 3, not by revenue: it must cover the down bucket. Size the caps to observed flows |
| Fees | management 0, performance 0 | Strategy `Rebalancer` fees are 0 as well |

### 5.1 Derived relations

Three configured values are **not** independent, so `registry.ts` computes them
instead of hardcoding them and asserts the relation at module load — a bad retune
throws before it can be deployed. A fourth relation is not derivable inside the
registry (it needs the per-chain confirmation depth), so it is checked only
off-chain. `ops/src/checks/deployment.ts` re-checks all four against the live
on-chain configuration in phase 4 and then continuously in the monitor. They span
two contracts and are set by separate Timelock calls, so no contract can enforce
them — every violation is a silent stall rather than a revert at the moment it is
introduced.

| # | Relation | Enforced in `registry.ts` | Deployed | What breaks without it |
|---|---|---|---|---|
| 1 | `maxSnapshotAge < 256 × hubBlockTime` | Yes (`SNAPSHOT_AGE_CEILING`) | 480 s < 512 s (Base, 2 s blocks) | Snapshots older than the `blockhash` window can never bind. Every commit reverts `InvalidHubReference`, which does not say "stale", so the operator debugs the wrong thing |
| 2 | `maxClearingDelay ≥ maxTickAge + maxSnapshotAge` | Yes | 8,580 s ≥ 7,200 + 480 s | A reference time precedes its commit by up to `maxSnapshotAge`, so below the sum every `clearDeposits`/`clearRedeems` reverts `TickNotUsable` while `bridgeSendsAllowed()` stays true and the updater looks fresh: a deadlock nothing signals |
| 3 | `instantFee ≥ downBucket.capacity` | Yes (`DOWN_BUCKET_CAPACITY`) | 0.25% ≥ 0.2% | Exiting just ahead of a pending `commitTick` that books a loss becomes risk-free profit, up to `dailyInstantLimit` per day, at the remaining holders' cost (threat model T18) |
| 4 | `minTickInterval ≥ confirmations × hubBlockTime` | No — monitor and phase 4 only | 300 s ≥ 10 × 2 s (Base) | The hub reference block can precede the previous commit's block, which `_validateHubBinding` rejects, so commits fail under normal confirmation lag |

### 5.2 Delta from the test fixture

`test/tick/TickFixture.sol` is deliberately not the deployment configuration. It
differs on: `minTickInterval` 0 (so tests can commit back-to-back),
`maxSnapshotAge` 1 h, `maxOverdueInFlight` `type(uint128).max` (breaker
effectively off), `maxInFlightRatio` 50%, `minDuration` 1 h,
`maxClearingDelay` 1 h, `minimumBuffer` and `minBufferRatio` both 0, and
`instantFee` 0.1%. The last two are the point: the fixture runs relation 2 and
relation 3 in their **broken** configuration, which is what
`testInstantFeeMustCoverTheDownBucket` and the clearing-delay tests exercise.

## 6. Hardcoded constants that bound policy

These are compiled in. No Timelock call changes them, so any configuration in §5
has to fit inside them, and changing one is a contract upgrade.

| Constant | Value | Where | What it bounds |
|---|---|---|---|
| `blockhash` window | 256 blocks | `TickAccountant._validateHubBinding` (`block.number - hubBlock > 256`) | `maxSnapshotAge`: on Base at 2 s blocks the hard ceiling is 512 s, and relation 1 keeps the configured value under it. Also caps how far a commit may lag its reference block, which is what forces the updater to retry rather than wait out an incident |
| `MAX_FUND_ITERATIONS` | 16 | `EpochVaultLogic._fund` | Epochs funded per call. Not a limit on total funding — `fund()` is permissionless and re-callable — but a backlog deeper than 16 unfunded epochs needs several transactions |
| `DEPOSIT_BLOCKING_FLAGS` | `(1 << 0) \| (1 << 1)` = down-move + overdue | `EpochVaultLogic` | Which Tick flags block deposit clearing. Adding `FLAG_IN_FLIGHT_LIMIT` (1 << 2) or `FLAG_CHAIN_EXPOSURE` (1 << 3) to it is a code change, not a configuration change; today neither blocks settlement |
| Instant-exit bucket window | 1 day | `EpochVaultLogic._consumeInstant` (`mulDiv(capacity, 1 days)`) | `dailyInstantLimit` is genuinely per rolling 24 h. There is no hourly or weekly variant to configure |
| `PROVIDER_VIEW_CALL_GAS` | 3,000,000 | `Rebalancer._safeGetDepositBalance` (`provider.getDepositBalance{gas: …}`) | The gas stipend per provider view. It decides which "slow" providers still count as healthy, and therefore when deposits get refused. A Morpho withdraw queue longer than this stipend reads as a failed provider |
| `Timelock.MIN_DELAY` | 30 minutes | `Timelock.MIN_DELAY` (also `MAX_DELAY` 30 days, `GRACE_PERIOD` 14 days) | The floor on every governance delay, including the 24 h delay this deployment uses. Nothing risk-increasing can be made instant through the Timelock, and nothing queued can be executed after 14 days |
| `NavSnapshot.VERSION` | 1 | `NavSnapshot.validateEncoding` | A new snapshot schema needs a version bump and a contract change; the encoding is not extensible by configuration |
| Fee ceilings | management 5%, performance 25% | `contracts/libraries/Constants.sol` | The most the Timelock (accountant) or ADMIN (strategy `Rebalancer`) can set. Deployed at 0 |
| Pause domains | 6 (vault), 2 (agent) | `DOMAIN_COUNT` in `EpochVault` / `ChainAgent` | The granularity of the breaker. A new pausable operation needs a new domain, i.e. a contract change |

## 7. Withdrawal latency: the real long pole

Deposit latency is what §4 tabulates, and it is bounded by configuration:
request → cutoff (≤ `maxDuration`) → next accepted Tick → `clearDeposits` →
`claim`. Worst case ≈ `maxDuration` + Tick interval, and it needs no liquidity
because a cleared deposit is paid in shares.

Withdrawal latency has the same first two legs and then a third that **no
configuration bounds**:

```
requestRedeem ──> closeEpoch ──> clearRedeems ──> fund ──> claim
   (epoch K)      ≤ maxDuration   needs a usable    needs free cash ≥ assetsOwed
                                  Tick after        for that epoch, strictly FIFO,
                                  cutoff, ≤         all-or-nothing
                                  maxClearingDelay
```

1. **Cutoff.** Up to `maxDuration` (6 h in production).
2. **Clearing.** `clearRedeems` needs `_usableTick`: latest accepted Tick,
   `referenceTime ≥ cutoff`, `now − committedAt ≤ maxTickAge`,
   `now − referenceTime ≤ maxClearingDelay`, not frozen. Bounded by
   `maxClearingDelay` = 2 h 23 min, in practice the next Tick (≤ 1 h). Clearing
   only creates a liability; it pays nothing.
3. **Funding — the long pole.** `_fund` reserves free cash for the oldest
   cleared, unfunded epoch, and only if `_freeCash() = cash − pendingDeposits −
   reserved` covers it **in full**. If it does not, the executor has to recall:
   * hub strategy: `deallocate` / `deallocateShares` then `returnToVault`. Fast,
     but it is a real withdrawal from Aave / Comet / Morpho, so it waits on market
     liquidity and on the withdraw queue — the unmeasured "rebalance duration" of
     §3;
   * spoke: `deallocate` on the spoke, `bridgeOut`, a **full CCTP round trip**
     (source finality, attestation, destination inclusion), `receiveBridge`, then
     `returnToVault` on the hub. Unmeasured; this is the number that decides
     whether a recall fits inside one epoch.
4. **FIFO and all-or-nothing compound it.** Because `_fund` returns on the first
   epoch it cannot cover rather than skipping it, one large epoch blocks every
   later, smaller epoch until it is funded in full. The extra latency that adds
   is unbounded in the size of the blocking epoch (`docs/crosschain-open-items.md`
   B6). Same-epoch deposits net against withdrawals automatically, since cleared
   deposits become free cash.
5. **`claim`.** Permissionless, O(1), paid by whoever calls it.

Consequences for cadence choice: a longer epoch reduces the number of funding
events but increases the amount each one has to raise, so it makes step 3 *more*
likely to need a bridge round trip, not less. `minimumBuffer` and
`minBufferRatio` are the only thing that makes step 3 unnecessary, and they are
sized against expected redemption flow, not against epoch length. The instant
exit is the only withdrawal path that skips steps 2–4, which is why it is
backward-priced and capped (§5, relation 3).

## 8. Operational cost per cadence

Per epoch the protocol needs one `closeEpoch`, one `clearDeposits`, one
`clearRedeems` and at least one `fund`; per Tick it needs one `commitTick` with a
3–4 KB calldata snapshot (§2). Claims are paid by users. On Base the L1 data fee
dominates a commit's cost, not its ~198k execution gas.

| Cadence | Ticks/day | Epochs/day | Keeper txs/day (commits + 3 per epoch + fund) | Snapshot calldata/day | Comment |
|---|---|---|---|---|---|
| 30 min epochs, 30 min Ticks | 48 | 48 | ~200 | ~150–190 KB | About 5× the 6 h default in transactions and 2× in calldata, for the best UX. Also doubles NAV-engine runs and the alert surface |
| every Tick (1 h Ticks) | 24 | 24 | ~100 | ~75–95 KB | Many near-empty epochs; each still costs three settlement transactions |
| **6 h epochs, 1 h Ticks** | 24 | 4 | **~40** | ~75–95 KB | **Deployed.** Commit cost is what transparency costs and does not depend on the epoch length; the epoch length only changes how often the three settlement transactions run |
| every 5 Ticks (~5 h) | 24 | ~4.8 | ~45 | ~75–95 KB | Same cost as the 6 h default, with a cadence that stretches automatically if Ticks slow down |
| every 10 Ticks (~10 h) | 24 | ~2.4 | ~35 | ~75–95 KB | Cheaper settlement, worse UX, largest intra-epoch rate move |
| 24 h epochs, 1 h Ticks | 24 | 1 | ~30 | ~75–95 KB | Cheapest settlement, and only marginally: 24 of the ~30 transactions are commits, which the epoch length does not change |

The cost of transparency (commits) and the cost of settlement (epochs) are
separate knobs. Choosing a slower epoch does not reduce the dominant term.

**Yield volatility versus yield forgone.** Forgone yield is what a queued
redemption gives up under `min(open, clear)`: roughly epoch length × APR, and it
is linear in the cadence (6 h at 8% APR ≈ 0.0055%, 24 h ≈ 0.022%). Volatility is
the different question and it is what should decide the cadence: how far the bid
rate can move *inside one epoch* relative to bucket capacity. If the worst
intra-epoch move exceeds `downBucket.capacity` (0.2%), Ticks quarantine and
clearing stalls until governance acts; if it exceeds `depositClearingMaxDown`
(0.1%), deposits wait. A cadence is safe only while its worst intra-epoch move
stays inside both. That distribution is unmeasured (§3), so the 6 h default is a
starting point rather than a measured-safe value.
