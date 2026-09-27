# Epoch and Tick frequency benchmark

Every value here is a **configuration**, not a constant:

* `TickAccountant.Config` and buckets, set with `setConfig` and `setBuckets`;
* `EpochVault.EpochConfig` and `Limits`, set with `setEpochConfig` and `setLimits`.

All of them change through the Timelock, with no contract replacement. This
document records what was measured, what the measurements imply, and what is
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

Source: `forge test --gas-report` on the fork-free suites (`test/tick/*`), with
solc 0.8.33, optimizer 200 runs, 2026-09-28. The fixture has 2 chains, up to 4
positions and a few in-flight entries.

| Call | Median gas | Max gas | Frequency |
|---|---|---|---|
| `TickAccountant.commitTick` | 181,966 | 289,699 (with fee mint) | per Tick |
| `EpochVault.closeEpoch` | 91,906 | 91,906 | per epoch |
| `EpochVault.clearDeposits` | 212,181 | 212,181 | per epoch |
| `EpochVault.clearRedeems` | 52,022 (empty) | 254,596 | per epoch |
| `EpochVault.requestDeposit` | 200,878 | 242,695 | per user action (includes checkpoint write) |
| `EpochVault.requestRedeem` | 142,796 | 142,796 | per user action |
| `EpochVault.claim` | 54,561 | 90,681 | per user action |
| `EpochVault.instantRedeem` | 112,621 | 168,743 | per user action |
| `ChainAgent.bridgeOut` (mock adapter) | 376,314 | 376,314 | per bridge leg |
| `ChainAgent.receiveBridge` (mock adapter) | 110,458 | 121,006 | per bridge leg |

Clearing is O(1) in the number of requests. Per-user work happens in `claim`,
paid by whoever claims.

**Calldata growth.** Each additional position is 7 words (224 bytes) and each
in-flight entry is 7 words. On Base, calldata cost is dominated by the L1 data
fee, not execution gas. A realistic snapshot (3 chains, about 10 positions, a
few transfers) is about 3–4 KB.

**Contract size.** `EpochVault` is 23,384 B of runtime code, leaving a 1,192 B
margin under EIP-170. Any further feature there requires splitting the contract.

## 3. Unmeasured (needs mainnet or fork observation)

| Quantity | Why it matters | How to measure |
|---|---|---|
| CCTP V2 standard and fast latency, Base↔Arbitrum and Base↔Ethereum | Sets `maxTransit` and how quickly an epoch can be funded from recalls | Send small canary transfers; timestamp `BridgeOut` against `BridgeIn` |
| Historic daily flows of the live vaults | Epoch deposit caps, instant daily limit | Index `Deposit`/`Withdraw` events of the live `Rebalancer`s |
| Max observed daily rate move of the strategy set | Bucket refill and capacity | Replay `convertToAssets` of the live strategies per hour over 90 days |
| L1 data fee on Base for a 4 KB commit | Tick cost | Measure on the first testnet or mainnet commits |

## 4. Candidate cadences

| Cadence | Deposit wait (avg / max) | Clearing txs/day | Netting | Assessment |
|---|---|---|---|---|
| Clear every Tick (1 h Ticks) | ~0.5 h / ~2 h | 24 × 3 | poor | Works. Many near-empty epochs; best UX |
| **6 h epochs, 1 h Ticks** | ~3.5 h / ~7 h | 4 × 3 | good | **Recommended starting point**: recalls fit inside one epoch if CCTP latency proves well under an hour |
| 24 h epochs | ~12.5 h / ~25 h | 1 × 3 | best | Fund-like (T+1); weak DeFi UX |

## 5. Recommended initial configuration (to be confirmed by §3)

| Parameter | Value | Reason |
|---|---|---|
| Tick cadence (operational) | 1 h, plus on material events | Transparency. Staleness guard `maxTickAge = 2 h` tolerates one missed Tick |
| `minTickInterval` | 5 min | Bounds commit spam; well under the cadence |
| `maxSnapshotAge` | 10 min | Must be under about 8.5 min of Base blocks for the `blockhash` binding; 10 min in time allows skew |
| `maxTransit` | 1 h | Placeholder until CCTP latency is measured |
| `EpochConfig.minDuration / maxDuration` | 4 h / 6 h | §4 |
| `EpochConfig.minTicks` | 1 | At least one accepted Tick inside the epoch |
| `EpochConfig.maxClearingDelay` | 1 h | Clearing must follow its Tick closely (design §5.6) |
| Up bucket | capacity 0.5%, refill 20% APR | Above any plausible stablecoin lending APR; one delayed-transfer recognition fits |
| Down bucket | capacity 0.2%, refill 0.1%/day | A larger loss needs ADMIN ratification |
| `depositClearingMaxDown` | 0.1% | Entries wait on a Tick that moved down more than this |
| `maxSpread` | 1% | Bounded by the in-flight share |
| `maxInFlightRatio` | 25% of navBid | Hub sends halt above it |
| Instant exit | per call 10k, per day 50k, fee 0.1%, `instantMaxTickAge` 2 h | Enabled with limits per the founder decision. Size to observed flows |

These are the values the test fixture uses, except `maxInFlightRatio` (50% there)
and `minTickInterval` (0 there, so tests can commit back-to-back).
