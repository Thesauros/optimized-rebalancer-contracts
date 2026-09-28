# Tick / Epoch accounting: design

Phase 0 deliverable, updated after implementation (branch
`feat/crosschain-tick-epoch`). It builds on `docs/current-architecture.md`; the
threats are in `docs/cross-chain-threat-model.md`; the as-built report is
`docs/implementation-report.md`.

## 0. Founder decisions (2026-09-27) and implementation deltas

| Question | Decision |
|---|---|
| Q1 hub chain | **Base** (8453) |
| Q2 strategies | New cross-chain contracts. **Revised 2026-09-28: the existing `Rebalancer` may be changed** ("меняй старый"); it is hardened in a storage-compatible way and used as the strategy |
| Q3 instant exit | **Enabled with limits** (per call, per day, fresh Tick, fee) |
| Q4 snapshot | **Full snapshot in calldata**, arithmetic checked on-chain |

Where the implementation differs from the proposal below, the implementation
is authoritative:

1. **`Rebalancer` hardened in place**, storage-compatible: one mapping is appended
   to the ERC-7201 struct; the reentrancy guard lives in its own OZ namespace and
   works uninitialized. The changes:
   * `nonReentrant` on deposit, mint, withdraw, redeem and rebalance;
   * provider balance views under a gas stipend, so a failing provider reads as 0
     instead of freezing the vault. **Deposits are refused while any provider is
     unhealthy**, because an incomplete NAV would over-mint;
     `providersHealthy()` exposes the state;
   * per-provider caps in bps of total assets, enforced after deposits and
     rebalances; ADMIN may lower a cap, only the Timelock may raise or remove it;
   * rebalance moves the measured amount released by the source;
   * a removed provider's approval is revoked, and the entry provider cannot be
     delisted.

   The fee high-water mark (sandbox Finding 6) is **not** included, because it
   changes fee semantics for live vaults. It remains a separate decision.
   `scripts/upgrade-vault-implementation.ts` still refuses any source change
   other than `Constants.sol`, so rolling this onto a live vault stays a
   deliberate, separately reviewed step.
2. **Hub binding uses per-block checkpoints.** `EpochVault` writes a checkpoint
   of (cash, pending deposits, liabilities, supply) at the end of every block
   that changes them. `commitTick` takes a checkpoint index and verifies it is
   the one in force at the hub reference block. This replaces the proposed "no
   change since the reference block" rule, which anyone could grief by making a
   request each block.
3. **The hub reference block must be within 256 blocks** (the EVM `blockhash`
   window), so every commit binds to a canonical hub block. On Base, with 2 s
   blocks, a snapshot must be committed within about 8.5 minutes of its hub
   reference block. It must also be at or after the previous commit's block, so
   fee shares minted then are included.
4. **Quarantine and freeze are separate flags.**
   * A quarantine is set by an out-of-bounds Tick. It is cleared by the next
     in-bounds Tick or by `ratifyTick`.
   * A guardian `freeze()` is cleared only by ADMIN `unfreeze()`.
   * Risk metrics (in-flight, overdue) set **flags** on an accepted Tick rather
     than quarantining it. Flags block deposit clearing and hub bridge sends —
     not uniformly: the down-move and overdue flags block deposit clearing and
     sends, the in-flight flag blocks sends only, and `FLAG_CHAIN_EXPOSURE`
     blocks sends *into* the marked chain only (§7).
5. **Deposits and redemptions clear independently** (two cursors). A Tick that
   is unusable for deposits (down-move or overdue flag) still clears
   redemptions. The deposits carry to the next usable Tick. An empty side clears
   without a Tick, because it uses no price.
6. **Instant exits consume the buffer.** `minimumBuffer` constrains
   `pushToAgent`, not instant exits. Neither can use cash owed to
   cleared-but-unfunded redemptions.
7. **Spoke agents cannot read the hub accountant.** Their pauses and route
   disables are guardian actions. The hub agent reads the accountant's breakers
   automatically.
8. **`EpochVault` is split** into the vault (token, roles, pauses, share
   movements) and the linked library `EpochVaultLogic` (epochs, clearing,
   funding, limits, buffer, checkpoints). They share the `EpochVaultStorage`
   layout.


Goal: the smallest architecture that makes this statement technically defensible:

> Thesauros maintains a transparent, independently reproducible view of capital
> across chains. Cross-chain operations are asynchronous state transitions.
> Economic state is committed in discrete Ticks. User operations clear in
> configurable Epochs. During uncertain or stale states, settlement is
> conservative, so the protocol cannot overpay against unconfirmed value.

---

## 1. Decisions in one table

| # | Decision | Chosen | Main reason |
|---|---|---|---|
| D1 | Topology | **Hub-and-spoke**: one share token and one accountant on a hub chain; spokes hold positions only | One supply, one rate, one queue. Multi-entry share tokens multiply every problem below by N |
| D2 | Strategy layer on each chain | **Reuse `Rebalancer`** (hardened in place, §0) as the per-chain strategy; a thin `ChainAgent` holds its shares | The provider valuation code, EXECUTOR constraints and Hexens-audited adapters already exist and are reproducible via `eth_call` |
| D3 | User entry | **Asynchronous** request → epoch clearing → claim (ERC-7540-shaped), plus an optional capped instant exit | Synchronous deposit/redeem against a lagged NAV *is* the stale-NAV arbitrage |
| D4 | Pricing | **Forward pricing** at a Tick observed *after* the epoch cutoff, with **dual rates** (bid for exits, offer for entries) | Forward pricing removes timing arbitrage; dual rates make "conservative" well-defined in both directions (§5) |
| D5 | Withdrawal price | `min(bid at epoch open, bid at clearing Tick)` | Blocks "exit before a loss is booked"; yield earned while queued stays with holders who keep bearing risk |
| D6 | Deposit price | `offer at clearing Tick` (no `max`) | Pending cash is not exposed to vault P&L; `max()` would confiscate depositor value on losses (§5.4) |
| D7 | NAV | Computed off-chain. The full snapshot is submitted **as calldata**; the contract recomputes the hash and the arithmetic, checks the hub-side fields against its own state, and bounds the rate | Arithmetic and hub liabilities are not trusted, only remote position values are |
| D8 | Rate limits | **Token buckets** per direction (capacity + refill), which cover per-tick, rolling and daily limits in O(1) state | Per-update bounds alone compound (BoringVault's accountant has only per-update bounds, verified) |
| D9 | Out-of-bounds Tick | Stored as **Quarantined**: settles nothing, trips the circuit breaker, governance may ratify | Rejecting a real loss would keep paying exits at the pre-loss price, the worst failure |
| D10 | Share lock | **Not added**. Shown redundant in §8 | Shares are minted only at clearing, at the offer price |
| D11 | Rebalancer control | Same-chain: existing provider whitelist plus per-provider caps (§0). Cross-chain: fixed routes (adapter, chain, peer agent) + per-route volume buckets. **No Merkle manager** | The action space is tiny and enumerable; Merkle verification solves a generic action space Thesauros does not have |
| D12 | Bridge (first) | Circle **CCTP V2**, USDC only, Ethereum/Base/Arbitrum | Burn/mint (no pool/slippage), destination-caller restriction, `hookData` carries our transfer id |

Out of V1: Plasma (USDT0, needs FX), Monad (CCTP availability not verified here),
spoke-side deposits, secondary-market share bridging, and reward-token recognition.

---

## 2. What is reused, what is new

### 2.1 Reused unchanged

| Component | Used as |
|---|---|
| `AaveV3Provider`, `CompoundV3Provider`, `MorphoProvider` | Per-chain position valuation and movement, via `Rebalancer` |
| `AccessManager`, `PausableActions` patterns, ERC-7201 layout | Roles and pause domains in every new contract |
| `Timelock` | Governance for all risk-increasing configuration |
| `VaultFactory` pattern | Atomic deploy+init for every new proxy |
| Test doubles in `test/unit/PerformanceFeeCap.t.sol` | Base for fork-free unit, fuzz and invariant suites |
| `scripts/upgrade-vault-implementation.ts` gating approach | Template for new deploy/upgrade gates |

### 2.2 Reused with modification

| Component | Change | Why |
|---|---|---|
| `Rebalancer` | **Done in place (§0 item 1), without the HWM.** Originally proposed: a new generation built from `crosschain-sandbox` Findings 1–8 (reentrancy guard, bounded provider views, HWM, approval revocation), plus **per-provider exposure caps** checked after `rebalance`/`deposit`, plus **measured amounts** in the rebalance leg | Becomes the spoke/hub strategy. The live per-chain vaults are **not** upgraded by this initiative (§11) |
| `MeshNode` route model (sandbox) | Immutable route endpoints, `maxFeeBps`, measured balance deltas, single-settlement transfer ids, explicit write-down with reason → carried into `ChainAgent` | Proven shape. Its round-trip-to-same-node model is replaced by peer-to-peer legs |
| `CCTPMeshBridgeAdapter` (sandbox) | Rewritten: V2 `depositForBurnWithHook`, `destinationCaller` = peer adapter, `hookData` = transfer id, **permissionless** delivery (no keeper-only relay) | The sandbox adapter uses the V1-compatible call and a trusted keeper, and cannot bind a transfer id to the mint |

### 2.3 New

| Contract / artifact | Chain | Responsibility |
|---|---|---|
| `TickAccountant` | Hub | Tick storage, snapshot hash and arithmetic check, rate buckets, staleness, fee accrual, quarantine |
| `EpochVault` | Hub | Share token; request/cancel/claim for deposits and withdrawals; epoch close and clear; liquidity buffer; instant exit |
| `ChainAgent` | Every chain (hub included) | Holds idle asset + strategy shares; allocate/deallocate to the local `Rebalancer`; `bridgeOut` along fixed routes; receives bridged funds with measured amounts |
| `CctpV2Adapter` | Every chain | Transport only: burn with hook, authenticate + mint, return `(transferId, srcChain, srcAgent)` |
| NAV snapshot spec + reference calculator | Off-chain | Deterministic snapshot builder (`docs/nav-reproduction.md`, Phase 6) |

### 2.4 Rejected

* **Upgrading the live `Rebalancer` vaults in place to the async model.** That
  would change the semantics of 50.8k USDC of existing Arbitrum deposits (instant
  exit becomes queued) and needs a migration audit. A new vault generation with
  opt-in migration is cheaper and safer.
* **Legacy `CrossChainVault` (other repo).** It is SEC-018: its ledger moves on
  keeper-set flags, reports can overwrite debt, it has no corridor, and it
  deposits at stale NAV. Only its good ideas are carried over (§13).
* **Veda `ManagerWithMerkleVerification`.** See D11. It also does not commit
  amounts (verified: leaves contain only addresses and `valueNonZero`), so it would
  not give us amount limits anyway.

---

## 3. Topology

```mermaid
flowchart TB
  subgraph HUB["Hub chain"]
    U((Users)) -->|requestDeposit / requestRedeem / claim| EV[EpochVault<br/>share token, queue, buffer]
    EV -->|reads accepted Tick| TA[TickAccountant]
    NU[NAV updater] -->|commitTick snapshot calldata| TA
    EV <-->|push / return cash| HA[ChainAgent hub]
    HA <-->|deposit / withdraw| HR[Rebalancer hub]
    HR -->|delegatecall| HP[Aave · Compound · Morpho]
    HA <--> HB[CctpV2Adapter]
  end
  subgraph S1["Spoke: Base"]
    BA[ChainAgent] <--> BR[Rebalancer] --> BP[Aave · Morpho]
    BA <--> BB[CctpV2Adapter]
  end
  subgraph S2["Spoke: Arbitrum"]
    AA[ChainAgent] <--> AR[Rebalancer] --> AP[Aave · Compound · Morpho]
    AA <--> AB[CctpV2Adapter]
  end
  HB <-. CCTP burn/mint .-> BB
  HB <-. CCTP .-> AB
  BB <-. CCTP .-> AB
  OFF[Off-chain NAV engine] -. reads all chains at a consistent cut .-> HUB & S1 & S2
  OFF --> NU
  EX[Executor] -->|allocate / deallocate / bridgeOut within limits| HA & BA & AA
```

Hub: Base (§0).

---

## 4. The Tick

### 4.1 Definitions

`rate` means asset units per share, scaled by `1e18` (`assets = shares · rate / 1e18`).

| Term | Meaning |
|---|---|
| Economic NAV | The true value, unknowable in real time |
| **Bid NAV** (recognized, conservative) | Values every uncertain item at its lowest plausible value. Used for **exits** |
| **Offer NAV** | Values uncertain items at their highest plausible value. Used for **entries** |
| Effective NAV | Bid NAV net of accrued fees; `rateBid = effectiveNAV / supply` |
| Spread | `offer − bid`: the size of the uncertainty. Zero when nothing is in flight or unresolved |

Why two numbers and not one: understating NAV protects the vault against exits,
but *hurts* it on entries, because depositors receive too many shares. No single
"conservative NAV" can protect both directions. Fund administration solved this
long ago with **dual pricing** (bid/offer), where each side is priced against the
side of the uncertainty that cannot hurt the fund. This design applies the same
rule to uncertainty instead of to market spreads.

### 4.2 Valuation rules (bid / offer)

| Item | Bid | Offer |
|---|---|---|
| `Rebalancer` shares held by a `ChainAgent` | `convertToAssets(shares)` at the reference block (already `min(real, book)` for Morpho and net of pending fees) | same |
| Idle asset in a `ChainAgent` | `asset.balanceOf(agent)` | same |
| Hub vault accounted cash | the vault's accounted cash (measured-transfer ledger, donations ignored) | same |
| Pending deposits (not yet cleared) | **excluded**: subtracted from cash | excluded |
| Cleared, unpaid withdrawals | **liability**: subtracted | subtracted |
| In-flight transfer, age ≤ `maxTransit` | `minReceive` recorded at send | `amountSent` |
| In-flight transfer, age > `maxTransit` (overdue) | `minReceive`; trips breaker `OVERDUE_IN_FLIGHT` if above threshold | `amountSent` |
| In-flight transfer written down by governance | `min(minReceive, amountSent − writtenDown)` | `amountSent − writtenDown` |
| Reward tokens (COMP, Morpho rewards) | 0 until swapped into the asset and held | 0 |
| Unclaimed/accrued fees | computed on-chain at commit (§4.5), not in the snapshot | — |

### 4.3 Consistent cut across chains (the non-obvious part)

Independently chosen reference blocks can **count the same dollar twice**. For
example, take the source chain's reference block *before* a `bridgeOut`, and the
destination chain's reference block *after* the matching receipt. The funds then
appear both as source idle and as destination idle. Invariant 3 needs a
**consistent cut**: no receipt inside the cut whose send lies outside it.

Deterministic rule, which is part of the snapshot spec:

1. Choose a reference timestamp `T`. On each chain, take the last block with
   `timestamp ≤ T`.
2. For every `BridgeIn(transferId)` at or before a destination reference block
   whose `BridgeOut(transferId)` lies *after* the source reference block, advance
   the source reference block to the block containing that `BridgeOut`.
3. Repeat step 2 until nothing changes. The process only moves blocks forward and
   is bounded by chain heads, so it terminates. The result is unique for a given
   `T`.
4. In-flight = transfers sent within the cut and not received within the cut.
   Each transfer id appears exactly once: in-flight, destination balance, or
   written down.

A checker recomputes the same cut from `T` and the chains' public logs.

### 4.4 Canonical snapshot and hash

The snapshot is an ABI-encoded struct, not JSON:

```solidity
struct ChainRef   { uint64 chainId; uint64 blockNumber; bytes32 blockHash; }
struct Position   { uint64 chainId; address holder; address strategy; uint8 kind;
                    uint256 units; uint256 valueBid; uint256 valueOffer; }
struct InFlight   { bytes32 transferId; uint64 srcChainId; uint64 dstChainId;
                    uint64 sentAt; uint256 amountSent; uint256 minReceive;
                    uint256 writtenDown; }
struct NavSnapshot {
    uint16 version;           // snapshot schema version
    uint64 tickId;            // must equal lastTickId + 1
    uint64 referenceTime;     // T
    ChainRef[]  chains;       // strictly ascending chainId
    Position[]  positions;    // strictly ascending (chainId, holder, strategy, kind)
    InFlight[]  inFlight;     // strictly ascending transferId
    uint256 hubCash;          // EpochVault accounted cash at hub reference block
    uint256 pendingDeposits;
    uint256 liabilities;      // cleared, unpaid withdrawals
    uint256 totalShares;      // EpochVault.totalSupply at hub reference block
}
navHash = keccak256(abi.encode(snapshot));
```

* **Ordering.** Strict ordering makes the encoding unique: the contract rejects
  unsorted or duplicate entries.
* **`kind`.** Enumerates `IDLE` and `STRATEGY_SHARES` in V1; new kinds need a
  version bump.
* **Derived values.** Rates and NAVs are **not fields**. They are derived from
  the fields by the contract (§4.5), so a snapshot cannot carry a rate that
  contradicts its own positions.
* **Cost.** About 20 positions and a handful of transfers is roughly 4–6 KB of
  calldata, or about 70–110k gas on Ethereum at 16 gas per non-zero byte. This
  has to be measured in Phase 1.
* **Fallback.** If calldata cost is ever unacceptable, commit only `navHash` plus
  the derived rates and publish the snapshot off-chain. That loses the on-chain
  arithmetic check; §12 Q4.

### 4.5 `commitTick` validation (in order)

1. `msg.sender` holds `NAV_UPDATER_ROLE`. Commits stay possible while
   quarantined or frozen, which keeps transparency; settlement is what stops.
2. **Identity and time.**
   * `tickId == lastTickId + 1`.
   * `referenceTime > previous.referenceTime`.
   * `referenceTime ≤ block.timestamp`.
   * `block.timestamp − referenceTime ≤ maxSnapshotAge`.
   * `block.timestamp ≥ lastCommit + minTickInterval`.
3. **Encoding** (`NavSnapshot.validateEncoding`). `version == 1`; every array is
   strictly ordered, which also rejects duplicates; each position has a known
   `kind` and `valueOffer ≥ valueBid`; each in-flight entry has
   `minReceive ≤ amountSent` and `writtenDown ≤ amountSent`.
4. **Membership** (`_validateMembership`). The snapshot's chain list equals the
   configured set, in the same order. Every position's `chainId` is in the
   configured set (`UnknownChain`) *and* its `holder` is a registered agent of
   that chain (`UnknownAgent`). The chain check is explicit because a chain can be
   dropped from the set while its agents stay marked, and such a position would be
   counted by `totals()` while being invisible to `chainBids()`. Both endpoints of
   every in-flight transfer must also be configured chains.
5. **Hub binding** (`_validateHubBinding`). Checked on-chain against the
   contract's own state and the vault's checkpoints.
   * The snapshot lists the hub chain; its `ChainRef.blockNumber < block.number`.
   * `block.number − hubBlock ≤ 256` (the EVM `blockhash` window) and
     `blockhash(hubBlock) == ChainRef.blockHash`.
   * `hubBlock ≥ _lastCommitBlock`, the block of the previous commit, so fee
     shares minted then are included.
   * The caller supplies `hubCheckpointIndex`; the checkpoint at that index must
     be the one in force at `hubBlock` (its block ≤ `hubBlock`, and the next
     checkpoint's block > `hubBlock`), and `hubCash`, `pendingDeposits`,
     `liabilities` and `totalShares` must equal that checkpoint. **The updater
     cannot under-report liabilities or shares.** If a vault state change lands
     between snapshot and commit, the commit reverts `HubStateMismatch` and is
     retried.
6. **Arithmetic** (`NavSnapshot.totals`). 
   * `navBid = Σ valueBid(positions) + Σ min(minReceive, amountSent − writtenDown)(inFlight) + hubCash − pendingDeposits − liabilities`.
   * `navOffer` is the same with offer values and `amountSent − writtenDown` for
     in-flight.
   * `navOffer ≥ navBid` is implied by step 3's per-entry checks.
   * Reverts `ZeroShares` if `totalShares == 0` or `navBid == 0`.
   * `grossBid = navBid · 1e18 / totalShares` and
     `grossOffer = navOffer · 1e18 / totalShares`, both floored.
7. **Risk metrics, computed before the bounds test.** `_riskFlags` derives
   `FLAG_DOWN_BEYOND_DEPOSIT_LIMIT`, `FLAG_OVERDUE_IN_FLIGHT` and
   `FLAG_IN_FLIGHT_LIMIT` from the snapshot; `_markChainExposure` derives
   `FLAG_CHAIN_EXPOSURE` and refreshes `overExposed[chainId]` from
   `NavSnapshot.chainBids` (§7). They are flags on the stored Tick, never a
   quarantine (§0 item 4).
8. **In bounds — two independent conditions, tested in this order.**
   * the spread bound `grossOffer ≤ grossBid · (1 + maxSpread)`; then
   * the corridor (§6.1) on `grossBid` against the previous accepted net bid rate,
     which spends bucket capacity via `_consumeBuckets`.
   The spread bound is first on purpose: `_consumeBuckets` consumes rate capacity,
   and a Tick that is going to be rejected must not drain the bucket
   (`testSpreadRejectionSpendsNoBucket`). `_lastTickId` and `_lastCommitBlock`
   advance whether or not the Tick is in bounds.
9. **If step 8 fails:** store the Tick as **Quarantined** with its flags, set
   `_quarantined`, emit, and return. Nothing settles on it.
10. **If it passes:**
   * **Fees on-chain.** The management fee is `navBid · mFee · dt / 365d`. The
     performance fee is `pFee · (rate − HWM) · supply` above the HWM, measured on
     *bid*, so fees are never charged on unrecognized value.
   * Mint fee shares, then compute net
     `rateBid = grossBid · (navBid − fee) / navBid` and the same for `rateOffer`.
   * Store the Tick as **Accepted**, advance `_lastAcceptedTickId`, raise the HWM
     if `rateBid` exceeds it, and clear `_quarantined`. A guardian `_frozen` is
     cleared only by ADMIN `unfreeze`.

Stored per Tick (append-only, never rewritten):

```solidity
struct Tick {
    uint64  referenceTime;
    uint64  committedAt;
    uint64  hubBlock;      // the bound hub reference block
    uint8   status;        // Accepted | Quarantined | Ratified
    uint8   flags;         // FLAG_DOWN_BEYOND_DEPOSIT_LIMIT | FLAG_OVERDUE_IN_FLIGHT
                           // | FLAG_IN_FLIGHT_LIMIT | FLAG_CHAIN_EXPOSURE
    uint128 rateBid;       // net of fees
    uint128 rateOffer;     // net of fees
    uint128 navBid;
    uint128 navOffer;
    bytes32 navHash;
}
mapping(uint64 tickId => Tick) ticks;   // plus TickCommitted event with the full header
```

`uint128` bounds a rate at 3.4e38, far above any reachable value (`1e18` = 1:1),
and a NAV at 3.4e38 base units, which is 3.4e32 whole tokens of a 6-decimal asset. A user operation proves its
accounting state by referencing a `tickId`; `EpochCleared` emits it.

---

## 5. Pricing

### 5.1 The asymmetric rule

With `R` the unknown true rate:

* An **exit** of `s` shares at price `p` over-pays remaining holders' value iff `p > R`.
  Safe side: `p ≤ R`, which is the **bid**.
* An **entry** of `a` assets at price `p` dilutes existing holders iff `p < R`.
  Safe side: `p ≥ R`, which is the **offer**.

Bid ≤ R ≤ offer holds by construction for every *recognized* uncertainty
(§4.2). What it cannot cover is a loss that is **unobservable at the reference
time** (§5.6).

### 5.2 Forward pricing

Every queued request is priced at a Tick whose `referenceTime` is **after the
epoch cutoff**. At request time nobody, including the updater, can know that
price. This is the mutual-fund forward-pricing rule, introduced to end exactly
the stale-NAV trading this brief describes. Requests after the cutoff roll to
the next epoch.

**Cancellation.** A request is cancellable by its owner while its epoch is open.
After the cutoff, only a **Deposit** whose epoch still has
`depositsCleared == false` may be cancelled; a Redeem is never cancellable past
the cutoff. The asymmetry is the pricing rule, not convenience: pending deposits
are excluded from NAV (`navBid = assets + hubCash − pendingDeposits −
liabilities`), so refunding one moves no price and cannot be used to leave at a
pre-loss rate, while a redemption's price is fixed only at clearing, so a late
cancel would hand the holder a free option on the epoch's yield at the remaining
holders' cost. The motivation is a real trap: a deposit caught in an epoch that
closed while the accountant was frozen or quarantined previously had **no exit at
all**, because clearing needs a usable Tick and cancellation needed an open
epoch.

### 5.3 Withdrawal price (D5)

`priceW(K) = min(rateBid(openTick_K), rateBid(clearTick_K))`. `openTick_K` is the
accepted Tick current when epoch K opened; its rate is stored on the epoch.

| Rule from the brief | Verdict |
|---|---|
| A. fixed at request price X | **Rejected.** A loss booked before clearing falls entirely on remaining holders; it is the legacy vault's rule |
| B. settle at X+δ (clearing price) | Safe against timing, but trusts one clearing Tick fully. An erroneously high clearing Tick pays out |
| C. `min(X, X+δ)` per request | Safest per request, but per-request prices break O(1) batch clearing |
| **D. epoch price, `min(open, clear)`** | **Chosen.** Blocks exiting ahead of a booked loss; caps a wrongly high clearing Tick at the open rate; O(1) clearing |
| E. base amount + later adjustment | **Rejected for V1.** Needs per-request tracking of future recognition, and a negative adjustment after payout is uncollectable |

Consequences, stated to users:

* **Yield stops at request.** Yield between epoch open and clearing on queued
  shares stays in the vault for the holders who remain exposed. Its size is about
  epoch length × APR (e.g. 6 h at 8% APR ≈ 0.0055%). It is deterministic and
  never silent.
* **Maximum loss while queued.** It is the down-bucket capacity (e.g. 0.1%). A
  larger loss quarantines the Tick, and clearing waits for governance. This
  protocol-level bound replaces a per-request `minAssets`, which cannot coexist
  with O(1) batch clearing.

### 5.4 Deposit price (D6)

`sharesOut = assets · 1e18 / rateOffer(clearTick_K)`, floored.

`max(oldRate, newRate)` was evaluated and rejected:

* **Timing is already covered.** Forward pricing makes timing irrelevant, so
  `max()` adds nothing against front-running a positive Tick.
* **It confiscates on losses.** On a real loss between request and clearing,
  `max()` charges the pre-loss price. The depositor's cash was pending, not
  deployed, and never bore that loss, so `max()` would transfer depositor value
  to existing holders. That is confiscation, not conservatism.
* **A wrongly low clearing Tick** (a malicious updater within the corridor) would
  gift shares to depositors. The protection is §6: any down-move beyond the down
  bucket quarantines, and deposit clearing never runs on a Tick that moved down by
  more than `depositClearingMaxDown`. Such a Tick only settles withdrawals, which
  it under-pays, the safe side.

### 5.5 Instant exit (optional, capped)

`instantRedeem(shares)` pays `rateBid(latest) · (1 − instantFee)`. Every one of
these must hold:

* no breaker is active, and the latest Tick is younger than `instantMaxTickAge`;
* the amount is at most `maxInstantWithdrawal` and within a daily bucket
  (`dailyInstantLimit`);
* free cash not owed to cleared, unfunded redemptions covers it (the buffer is
  what instant exits draw on; `minimumBuffer` limits how much the executor may
  push out, see §0 item 6).

This is backward pricing, so it is **the one path open to stale-state
exploitation**. A holder who observes an on-chain loss before it is booked can
exit at the old bid. A pending `commitTick` is public calldata, so its rate is
known before it lands: exiting just ahead of a Tick that books a loss avoids that
loss and costs only `instantFee`. The front-run therefore pays exactly when the
loss can exceed the fee, and the largest loss one **accepted** Tick can book is
the down bucket's capacity (a larger move quarantines and settles nothing). That
gives the calibration rule

```
instantFee ≥ downBucket.capacity
```

Deployed: `instantFee = 0.25%` against `downBucket.capacity = 0.2%`. With the
rule satisfied, the net exposure of the whole path is
`dailyInstantLimit × (loss − instantFee) ≤ 0` for any loss one accepted Tick can
carry, so the residual is confined to moves that quarantine — where nothing
settles until governance acts. The rule is asserted at module load in
`deploy/crosschain/registry.ts`, checked at deploy and continuously by the
monitor, and demonstrated in both configurations by
`AdversarialScenarios.t.sol::testInstantFeeMustCoverTheDownBucket`. The guardian
pauses `DOMAIN_INSTANT_EXIT` on incident. By founder decision (§0) it launches
enabled, with limits; values in `docs/epoch-benchmark.md` §5.

### 5.6 Positive and negative deltas

* **Unrecognized positive value** comes from yield accrued after `T`, in-flight
  amounts above `minReceive`, and rewards. It is recognized in a later Tick and
  accrues to whoever holds shares then. Holders who exited earlier at bid do not
  receive it; it stays in the vault (model 1 of the brief). The amount is bounded
  by the spread plus epoch-length yield. It is deterministic and never lost: it
  sits in `navBid` from the recognizing Tick on.
* **Recognized negative value** (an overdue transfer, a write-down, Morpho bad
  debt) is in bid immediately. Exits clear at the lower price and entries pay
  offer. A move beyond the down bucket quarantines.
* **Unobservable loss at `T`** (an exploit that happens after `T`, before
  clearing) is the irreducible residual. **No accounting design removes it.**
  Exposure is bounded by:
  1. the clearing lag. `_usableTick` requires **both**
     `now − tick.committedAt ≤ maxTickAge` **and**
     `now − tick.referenceTime ≤ maxClearingDelay`, so the window in which an
     unobserved loss can be paid for at the pre-loss rate is at most
     `maxClearingDelay` after `T`. Deployed: `maxClearingDelay = maxTickAge +
     maxSnapshotAge + 15 min = 2 h + 8 min + 15 min = 2 h 23 min`, derived in
     `registry.ts` (the 15 min is build and inclusion slack for the NAV service);
  2. batch size, since withdrawals are paid only from liquidity;
  3. guardian pause of `Clearing`;
  4. Morpho's `min(real, book)` and CCTP's burn/mint (no pool) removing the two
     most common silent-loss sources.

---

## 6. Rate corridor, buckets and quarantine

### 6.1 Buckets (D8)

One bucket per direction, measured in WAD fractions of the previous accepted net
bid rate:

```
up.level   = min(up.capacity,   up.level   + up.refillPerSec   · dt)
down.level = min(down.capacity, down.level + down.refillPerSec · dt)
move = (grossBid − prevRateBid) / prevRateBid
accept iff  move ≥ 0 ? move ≤ up.level   (up.level   −= move)
                     : −move ≤ down.level (down.level −= −move)
```

* **Bounded over any window.** The total upward movement over any window `W` is
  at most `up.capacity + up.refillPerSec · W`. This is a true rolling bound in two
  storage slots, and it defeats "+0.5% per Tick, many Ticks".
* **Meaning of the parameters.** `up.refillPerSec` is the maximum believable APR
  of the strategy set; `up.capacity` is the largest single recognition event
  allowed without governance (e.g. a delayed transfer arriving).
* **Configuration.** All four values are configurable through the Timelock. None
  is hard-coded, and the examples in this document are placeholders for
  benchmarking.
* **Optional hard ceiling.** `maxMovePerTick ≤ capacity` can be added as a
  separate ceiling if wanted. The bucket already caps a single Tick at capacity.

### 6.2 Quarantine instead of revert (D9)

BoringVault's accountant pauses on an out-of-bounds update but still writes the
new rate (verified). This design goes one step further and **never settles on an
anomalous Tick**:

* **Storage and settlement.** The Tick is stored with status `Quarantined` and
  keeps its id. It is not the latest accepted Tick, so clearing (which needs an
  accepted Tick after cutoff) and instant exits wait.
* **Breaker.** It trips `QUARANTINE`, which pauses deposit clearing, withdrawal
  clearing, instant exits, outbound bridge sends and allocations to strategies.
  Requests, cancels (including the post-cutoff deposit cancel of §5.2), claims of
  already-funded withdrawals, and recalls of capital towards the hub stay open.
* **Resolution** is one of:
  * a later honest Tick that falls inside the buckets computed from the last
    **accepted** Tick; or
  * `ratifyTick(id)` by `ADMIN_ROLE` (Safe), no Timelock. It sets the latest
    Tick's status to `Ratified`, makes it the latest accepted Tick, clears the
    quarantine and emits `TickRatified`. It charges no fee on the ratified Tick
    and does not raise the high-water mark. **It does not touch the buckets:**
    neither level, capacity, refill rate nor `updatedAt` is read or written there.
    That is deliberate. A ratification is governance asserting that an
    out-of-corridor rate is the real one; if it also refilled or reset the
    buckets, one ratification would hand back the rate capacity the anomalous
    move just consumed, and a sequence of large moves could each be ratified into
    a fresh full bucket — turning the rolling bound of §6.1 into a per-Tick bound
    again. Leaving the buckets alone means the corridor still has to refill by
    time after a ratification, so the bound over any window is unchanged.
    It is an evented decision for real large losses or recoveries.
* **Safety versus liveness.** A compromised updater can force quarantine
  repeatedly. That is a liveness failure, not a safety failure. The guardian can
  only `freeze()`; revoking `NAV_UPDATER_ROLE` needs `ADMIN_ROLE`
  (`AccessManager.revokeRole`), so rotation is a Safe action.

---

## 7. Circuit breakers (granular)

| Trigger | Detected by | Effect |
|---|---|---|
| Tick outside buckets or spread | `commitTick` | Quarantine (§6.2). This is the only trigger that quarantines |
| Stale: `now − latestAccepted.committedAt > maxTickAge` | any settle path | Clearing and instant exits revert; requests still accepted (they are forward-priced, so safe) |
| `overdueInFlight > maxOverdueInFlight`, where overdue means age > `maxTransit` at the reference time | `commitTick` → `_riskFlags` | Sets `FLAG_OVERDUE_IN_FLIGHT` **on the accepted Tick**. Nothing is paused and the Tick still settles redemptions. The flag then blocks deposit clearing (`DEPOSIT_BLOCKING_FLAGS`) and hub sends (`_bridgeSendsAllowed`). Two thresholds are involved: `maxTransit` decides what counts as overdue, `maxOverdueInFlight` decides how much of it is tolerated — deployed at 0, so a single overdue unit trips it |
| `inFlight > navBid · maxInFlightRatio / 1e18` | `commitTick` → `_riskFlags` | Sets `FLAG_IN_FLIGHT_LIMIT` on the accepted Tick. Blocks hub sends only; it is **not** in `DEPOSIT_BLOCKING_FLAGS`, so deposit clearing continues |
| `chainBids[i] > grossBidAssets · maxChainExposure / 1e18` | `commitTick` → `_markChainExposure`, from `NavSnapshot.chainBids` | Sets `FLAG_CHAIN_EXPOSURE` and `overExposed[chainId]`. The denominator is **gross** bid assets (`navBid + pendingDeposits + liabilities`), not NAV: netting off pending deposits and liabilities would inflate every chain's apparent share past 100% during a large deposit or redemption epoch and latch the flag for a reason unrelated to concentration. `chainSendAllowed(dst)` — what the hub `ChainAgent.bridgeOut` calls — is `bridgeSendsAllowed() && !overExposed[dst]`, so it blocks sends **into** an over-cap chain only. It never blocks sends out of that chain, never blocks settlement, and is not in `DEPOSIT_BLOCKING_FLAGS`. In-flight value is excluded from `chainBids` (it belongs to no chain and is bounded by `maxInFlightRatio`) but sits in the denominator, so the shares sum to slightly under 100% — the conservative direction. Hub accounted cash counts as hub exposure. `maxChainExposure = 0` disables it, which is the deployed value |
| Per-protocol exposure above `capBps` | `Rebalancer` after every deposit and rebalance | Rejects the allocation. `capBps == 0` means uncapped, which is the default and what the entry provider ships at |
| Guardian call | `GUARDIAN_ROLE` | Pause any domain; unpausing needs `ADMIN_ROLE`. On the accountant the guardian's only action is `freeze()` |

Pause domains: six on `EpochVault` (`DOMAIN_DEPOSIT_REQUEST`,
`DOMAIN_REDEEM_REQUEST`, `DOMAIN_DEPOSIT_CLEARING`, `DOMAIN_REDEEM_CLEARING`,
`DOMAIN_INSTANT_EXIT`, `DOMAIN_ALLOCATE`, which also gates `pushToAgent`) and two
on `ChainAgent` (`DOMAIN_ALLOCATE`, `DOMAIN_BRIDGE_OUT`). **Never pausable by the
breaker:** claims of funded withdrawals, `cancel`, recalls to the hub, and
receipt of in-flight funds (`receiveBridge` has no domain). Exits already owed
must stay payable. This is granular per the brief; there is no single global
pause. Note that "no pause domain" is not "cannot be blocked": `deallocate` and
`deallocateShares` call into the strategy, whose own `Actions.Withdraw` pause is
`ADMIN_ROLE` with no Timelock (threat model T27).

---

## 8. Epochs

### 8.1 Lifecycle

```mermaid
stateDiagram-v2
  [*] --> Open: epoch K opens (stores openRateBid)
  Open --> Open: requestDeposit / requestRedeem / cancel (either kind)
  Open --> Closed: closeEpoch() when<br/>(elapsed ≥ minDuration ∧ acceptedTicks ≥ minTicks)<br/>∨ elapsed ≥ maxDuration
  Closed --> Closed: cancel(deposit) while depositsCleared == false<br/>→ refund, NAV-neutral (a Redeem can no longer be cancelled)
  Closed --> Cleared: clearDeposits() / clearRedeems() with the latest<br/>Accepted Tick: referenceTime ≥ cutoff, fresh, within maxClearingDelay,<br/>no freeze, and no DEPOSIT_BLOCKING_FLAGS for the deposit side
  Cleared --> Funded: free cash ≥ owed (FIFO by epoch)
  Funded --> [*]: users claim shares / assets
  Closed --> Closed: Tick quarantined or stale → wait
```

Parameters (`minDuration`, `maxDuration`, `minTicks`, `maxClearingDelay`) are
configurable through the Timelock. Tick frequency and epoch frequency are
independent: Ticks can land hourly for transparency while clearing runs every
`maxDuration`.

### 8.2 O(1) clearing

For epoch K with total deposit assets `D`, escrowed withdrawal shares `W`, and
clearing Tick `T`:

```
sharesMinted = floor(D · 1e18 / rateOffer(T))      // minted to the vault, claimed pro-rata
priceW       = min(openRateBid_K, rateBid(T))
assetsOwed   = floor(W · priceW / 1e18)             // W escrowed shares burned now
cash: D moves from pendingDeposits to free cash; liabilities += assetsOwed
per user: shares_i = floor(d_i · 1e18 / rateOffer), assets_i = floor(w_i · priceW / 1e18)
```

Per-user floors sum to at most the aggregate floor, so claims never exceed what
was minted or reserved. The dust stays in the vault as dead value. Clearing is
**permissionless**: its result is fully determined by stored totals and the Tick,
so there is no settler role to trust and no ordering to exploit.

### 8.3 Funding and claims

Epochs are funded strictly FIFO. `fund()` (permissionless) reserves free cash for
the oldest cleared, unfunded epoch once it can cover it in full. Same-epoch
deposits net against withdrawals automatically, because `D` becomes free cash at
clearing. Claims pay a funded epoch's `assets_i`. There is no partial funding of
an epoch in V1, which keeps it simple. The cost is that one large epoch delays
later small ones.

### 8.4 Request records

```solidity
struct Request {         // one struct for both kinds, keyed by requestId
    address owner;       // share owner (redeem) or payer (deposit)
    address receiver;
    uint64  epoch;
    uint8   kind;        // Deposit | Redeem
    uint8   status;      // Requested | Cancelled | Claimed
    uint128 amount;      // assets (deposit) or shares (redeem)
}
```

The brief's status list maps as follows: REQUESTED and CANCELLED are stored.
CLEARED, QUEUED, LIQUID and CLAIMABLE are **derived** from the epoch state
(Cleared/Funded), not stored per request. COMPLETED is stored as Claimed. EXPIRED
is not used: claims never expire, because an owed exit must stay payable.

CANCELLED is reachable from REQUESTED in exactly two situations, decided in
`EpochVaultLogic.cancel`; only the request owner may call it:

| Request epoch | Deposit | Redeem |
|---|---|---|
| Still the current epoch (open) | Cancellable | Cancellable |
| Closed, `depositsCleared == false` | **Cancellable** — refund of pending deposits is NAV-neutral | Not cancellable |
| Closed, `depositsCleared == true` | Not cancellable (already priced; `claim` pays) | Not cancellable |
| Claimed | Not cancellable | Not cancellable |

There is no pause domain on `cancel`, so it also works while the accountant is
frozen or quarantined — which is the case it exists for (§5.2).

### 8.5 Share lock: redundant (D10)

The claim to prove is that no path mints shares at a price below `R`.

* The only mint path is clearing, at `rateOffer ≥ R` for all recognized
  uncertainty.
* The only exits are the queue (`≤ rateBid`, forward-priced) and instant
  (`≤ rateBid · (1 − fee)`, capped).
* A round trip deposit → exit therefore loses at least `spread + fee`.
* "Deposit before a positive Tick" is priced *at* that Tick.
* Transfers, second accounts, wrappers and delegated withdrawals change who holds
  a share, not the price at which it was minted or can exit.

A lock would add state and a transfer hook without closing any path. The
Phase 7 tests assert the negative results: deposit one block before or after a
Tick, repeated deposits, and exit via a second account.

---

## 9. Cross-chain movement

### 9.1 ChainAgent

The executor can do exactly this, and nothing else:

| Function | Constraint |
|---|---|
| `allocate(amount)` | Deposits idle into **the** configured local `Rebalancer` (timelocked address). The recipient is the agent itself |
| `deallocate(amount)` | Withdraws that exact asset amount from the `Rebalancer` to the agent; the received amount is measured and must equal `amount`. **Always allowed**, even under breaker |
| `deallocateShares(shares, minAssets)` | Redeems `shares` of the strategy, which releases a variable amount, so the executor states a floor. The received amount is still measured, and below `minAssets` it reverts `SlippageExceeded`. This closes the asymmetry with `deallocate`, which enforces exactness |
| `bridgeOut(routeId, amount, minReceive, rebalanceId)` | The route is `(adapter, dstChainId, dstAgent)`, fixed by the Timelock. There is `amount ≤ route.maxPerTransfer`, and a per-route daily bucket. `minReceive ≥ amount · (1 − route.maxFeeBps)`. On the hub it also requires `accountant.chainSendAllowed(dstChainId)`. The debit is **measured**: the token balance delta must equal `amount` |
| `returnToVault(amount)` (hub agent only) | The recipient is hard-wired to `EpochVault` |

`deallocate` and `deallocateShares` have no agent pause domain, but they call
into the strategy, whose `Actions.Withdraw` pause is `ADMIN_ROLE` with no
Timelock: ADMIN can therefore block recalls instantly (threat model T27).

Receipt, `receiveBridge(adapter, payload)`:

1. The call is **permissionless**, which gives liveness without a trusted relayer.
2. The agent records its balance, calls the adapter, which authenticates and
   mints to the agent, then records its balance again.
3. `received = delta`. It requires that `(srcChainId, srcAgent)` is a configured
   peer, and that `transferId` has not been seen before (replay protection).
4. It emits `BridgeIn(transferId, srcChainId, received)`.

On the source chain, an in-flight amount cannot be decremented, because the
source cannot observe completion. So the **hard on-chain bound is the route
volume bucket**: in-flight at any instant is at most
`capacity + refill · maxTransit`. The accountant additionally breaks on the
in-flight amount derived from the snapshot. This replaces the legacy vault's
keeper-set statuses: **every accounting fact is an event emitted by a measured
token movement**.

### 9.2 State machine (reconstructed from events)

```mermaid
stateDiagram-v2
  [*] --> STARTED: rebalanceId chosen by executor
  STARTED --> WITHDRAWING_SOURCE: Deallocated(src)
  WITHDRAWING_SOURCE --> SOURCE_LIQUID: agent idle ≥ amount
  SOURCE_LIQUID --> IN_FLIGHT: BridgeOut(transferId, rebalanceId, sent, minReceive)
  IN_FLIGHT --> DESTINATION_RECEIVED: BridgeIn(transferId, received)
  IN_FLIGHT --> DELAYED: age > maxTransit
  DELAYED --> DESTINATION_RECEIVED: BridgeIn
  DELAYED --> RECOVERY_REQUIRED: governance review
  RECOVERY_REQUIRED --> WRITTEN_DOWN: writeDown(transferId, loss, reason)
  WRITTEN_DOWN --> DESTINATION_RECEIVED: late BridgeIn (recovery booked to same id)
  DESTINATION_RECEIVED --> DEPLOYING: Allocated(dst)
  DEPLOYING --> COMPLETED
  STARTED --> CANCELLED: no BridgeOut emitted
```

On-chain state is kept to the minimum that enforces safety:
`sent[transferId] = (amount, minReceive, time)` at the source, and
`received[transferId]` at the destination. `rebalanceId` is carried in events
only. The composite state above is what the indexer and the dashboard derive.
**CCTP has no FAILED terminal**, because a burn is final. "Failed" therefore means
"not yet minted", which is DELAYED/RECOVERY_REQUIRED, and the funds remain
claimable by anyone who delivers the attestation.

### 9.3 Bridge loss and fees

A fee or shortfall is recognized at receipt as `sent − received`. It is visible
in the next Tick because the destination balance is measured. While in flight,
bid carries `minReceive` and offer carries `amountSent`. CCTP standard transfers
have no protocol fee; fast transfers have a `maxFee` that is bounded by
`route.maxFeeBps`. An overdue transfer can be written down by governance. A late
receipt books the recovery against the same `transferId`, and a written-down id
can never be reused.

### 9.4 Bridge abstraction

`IBridgeAdapter` has two functions: `send(transferId, amount, dstChainId, dstAgent, minReceive)`
and `finalize(payload) → (transferId, srcChainId, srcAgent)`. Core accounting only
ever sees transfer ids and measured balances. Security differences stay explicit
per adapter, in `docs/cross-chain-threat-model.md` §5:

* CCTP: Circle attesters; burn/mint; no liquidity risk.
* LayerZero/Stargate: DVN configuration; pool liquidity; slippage.

---

## 10. Roles

| Role | Holder (target) | Allowed | Prohibited | Worst case if compromised |
|---|---|---|---|---|
| Governance (`Timelock`) | Safe-owned Timelock | Routes, peers, strategy addresses, buckets, limits, fees, epoch params | anything instant | Everything, after the delay; monitoring must watch the queue |
| `ADMIN_ROLE` | Safe | Role grants and revocations (there are no role admins), unpause, `ratifyTick`, `writeDown`, and on each strategy `Rebalancer`: `pause(Withdraw)`, `setManagementFee` ≤ 5% and `setPerformanceFee` ≤ 25% — all instant, no Timelock | Config changes that the Timelock owns | Ratify a bad Tick → mis-settle one epoch at an unbounded rate; pause strategy withdrawals → block every recall and every queued redemption (threat model T27–T29) |
| `NAV_UPDATER_ROLE` | Dedicated key/service | `commitTick` | Everything else | Rate moves within buckets per window, or forced quarantine (DoS) |
| `EXECUTOR_ROLE` | Rebalancer bot | allocate / deallocate / bridgeOut within limits, vault↔agent within buffer | Choose recipients, adapters or chains; exceed buckets | Misallocation; bridge volume up to bucket capacity along fixed routes |
| `GUARDIAN_ROLE` | Ops multisig/EOA | Pause any domain | Unpause | Liveness: pauses the vault |
| (none) | anyone | `closeEpoch`, `clearDeposits`, `clearRedeems`, `fund`, `claim`, `cancel` (by the request owner), `receiveBridge` | — | — |

**Hard prerequisite.** SEC-001 (ProxyAdmin owned by an EOA) must be closed for
every new proxy **before** any TVL. Otherwise the ProxyAdmin key bounds every
guarantee in this table.

---

## 11. Upgrade and migration

* **New proxies.** `EpochVault`, `TickAccountant` and `ChainAgent` are new
  contracts, so there are no storage-compatibility constraints. Each has its own
  ERC-7201 namespace and is deployed atomically (`VaultFactory` pattern). Their
  ProxyAdmins are owned by the Safe from deployment.
* **Strategy `Rebalancer` instances** for the agents are new deployments of the
  hardened generation. The live per-chain vaults are untouched. Users migrate by
  choice: redeem from the old vault, request a deposit in the new one. There is
  no forced migration and no change to the old vaults' semantics.
* **Live vault upgrades.** If the hardened `Rebalancer` generation is later rolled
  onto the live vaults, that is a separate, independently audited change
  (`initializeV2` pattern). It is **not** a dependency of this design.

---

## 12. Open questions for the founder

**All but Q6 are resolved.** The decisions are recorded in §0 and are what the
code implements; the recommendations below are kept as the Phase 0 record, and
where the decision went the other way that is stated explicitly.

| # | Question | Phase 0 recommendation | Status |
|---|---|---|---|
| Q1 | Hub chain: Ethereum or Arbitrum? | Ethereum for partners and custody. Arbitrum if user gas and today's TVL matter more. Tick cost is fine on either (≈ 24 commits/day) | **Resolved (§0): Base (8453)** — a third option, not either of the two offered. The 256-block `blockhash` window at 2 s blocks is what sets `maxSnapshotAge` |
| Q2 | Strategy on spokes: dedicated `Rebalancer` instances or the existing public vaults? | Dedicated instances (hardened generation). The public ones carry SEC-001 and have no provider caps | **Resolved (§0, revised 2026-09-28):** the existing `Rebalancer` source may be changed. It is hardened in place, storage-compatible, and new instances of it are deployed as the per-chain strategies (§11). The live public vaults are still not touched |
| Q3 | Instant exit at launch? | Disabled (limits = 0) until monitoring and the guardian are live | **Resolved (§0): enabled with limits.** This recommendation was **overridden by the founder decision**: per-call and per-day caps, fresh-Tick requirement and a fee, calibrated by `instantFee ≥ downBucket.capacity` (§5.5) |
| Q4 | Snapshot in calldata (on-chain arithmetic) or hash-only? | Calldata; measure the gas in Phase 1 | **Resolved (§0): full snapshot in calldata.** Measured: `commitTick` median about 198k gas (`docs/epoch-benchmark.md` §2). The hash-only fallback of §4.4 is not used |
| Q5 | Initial epoch parameters | Placeholder: Tick every 1 h, `maxDuration` 6 h, `minTicks` 1. To be replaced by `docs/epoch-benchmark.md` with measured CCTP latency and clearing gas (§14) | **Resolved for launch** by `deploy/crosschain/registry.ts` (production: 4 h / 6 h / `minTicks` 1, `maxClearingDelay` derived) and justified in `docs/epoch-benchmark.md` §4–§5. Still to be retuned once CCTP latency is measured on mainnet |
| Q6 | Legacy `CrossChainVault` on Base still accepts deposits at a ~24× wrong price | Pause deposits there (deployer key); see threat model §3 | **Open**, and the question changed: the founder reports not having deployed it, while on-chain it was created by the Thesauros deployer key. Tracked as C5 in `docs/crosschain-open-items.md` |

---

## 13. Lessons carried from the legacy system (SEC-018)

| Legacy mistake | This design |
|---|---|
| Ledger moved by keeper-set status flags; a never-dispatched 3.7 USDC left NAV | Every accounting fact is an event of a **measured** token movement; no status setters |
| A report could overwrite the debt ledger / set value to 0 | Snapshots cannot write state; the corridor bounds the rate; big moves quarantine |
| No report nonce; future timestamps accepted | `tickId = last + 1`; `referenceTime ≤ block.timestamp`, monotonic |
| In-flight moved by requested amount | Measured `received`; `minReceive`/`sent` bounds while in flight |
| Deposits at a stale/unverified NAV | Deposits only at clearing, forward-priced, offer side |
| Withdrawal price fixed at request | `min(open, clear)` |
| Keeper-chosen adapter, free-form calldata | Fixed routes; executor picks only route id and amount |
| One EOA held every role | Role table §10; SEC-001 is a precondition |
| Tests called the state-transition setter without the real dispatch | Invariant tests drive only public entry points with real token movement (mock bridge moves tokens) |

Kept from the legacy system: named NAV buckets in one view, degraded mode on
stale reports, the residual-liquidity floor, reserving funded obligations before
claims, and per-id single execution.

---

## 14. Epoch frequency (preliminary; full study in Phase 6)

With forward pricing, **epoch length no longer controls stale-NAV exposure**. It
trades UX against netting, gas and operations:

| Cadence | Deposit wait (avg / max) | Withdrawal wait (ex-liquidity) | Clearing txs/day | Netting | Comment |
|---|---|---|---|---|---|
| every Tick (1 h) | ~0.5 h / ~2 h | same | 24 | poor | fine technically; many tiny epochs; more Ticks carry settlement weight |
| 6 h | ~3.5 h / ~7 h | same | 4 | good | ≫ one CCTP round trip (standard ≈ source finality) so recalls fit inside one epoch |
| 24 h | ~12.5 h / ~25 h | same | 1 | best | T+1 fund-like; poor for DeFi UX |

This table is the Phase 0 sketch. `docs/epoch-benchmark.md` §4 is the current
study: it adds the tick-count cadences that `EpochConfig.minTicks` supports
directly (every 5 Ticks, every 10 Ticks) and a 30 min cadence as researched
variants, and it separates withdrawal latency from deposit latency.

Deployed values, all derived in `deploy/crosschain/registry.ts`: `minDuration`
4 h / `maxDuration` 6 h / `minTicks` 1 in the production profile, and
`maxClearingDelay = maxTickAge + maxSnapshotAge + 15 min = 2 h 23 min`. The
"withdrawal wait (ex-liquidity)" column above covers only up to clearing; the
funding leg is separate and is what `maxClearingDelay` bounds, not the epoch
length. `instantFee` is 0.25%, set by the calibration rule of §5.5 rather than by
the cadence, so it does not change with any row of this table.

Still to be measured before choosing defaults:

* CCTP V2 standard and fast latency per route (fork tests plus mainnet
  observation);
* `commitTick` and `clearEpoch` gas;
* historic daily flow of the live vaults;
* the maximum observed daily rate move of the strategy set, which calibrates the
  buckets.

---

## 15. Invariants (to be tested in Phase 7)

1. Paid + owed exits never exceed the value of burned shares at `priceW ≤ rateBid`
   (no over-distribution).
2. `rateBid` changes only through accepted or ratified Ticks. Uncertainty lowers
   bid or widens the spread; it never raises what exits receive.
3. Each `transferId` is in exactly one of {source idle, in-flight, destination,
   written down} in any consistent cut. The same underlying capital is never in
   two states.
4. `tickId` is strictly monotonic.
5. Stored Ticks are never modified (status transitions only Quarantined → Ratified).
6. `received[transferId]` is set at most once.
7. No executor call sequence moves the asset to an address outside
   {local Rebalancer, route adapter → configured peer agent, EpochVault}.
8. For every route, the volume in any window is at most
   `capacity + refill · window`.
9. deposit → exit round trips never profit, whatever the timing relative to Ticks.
10. `grossBid` moves beyond the buckets only via quarantine and ratification.
11. Cumulative upward movement over any window is at most
    `up.capacity + up.refill · window`.
12. A request is claimed at most once.
13. After clearing, `totalSupply` equals previous supply + `sharesMinted` + fee
    shares − `W`, and claimable shares plus dust equals `sharesMinted`.
14. While a domain is paused, no function in that domain changes state; funded
    claims and recalls are always possible.
15. With `maxChainExposure` enabled, no accepted Tick leaves a chain's
    `chainBids` share of `navBid` above the cap without setting
    `FLAG_CHAIN_EXPOSURE` and `overExposed[chainId]`, and while that mark stands
    `chainSendAllowed(chainId)` is false — so no further capital can be sent into
    it. Sends out of it and all settlement stay possible. With the cap at 0 (the
    deployed value) no chain is ever marked
    (`testChainExposureDisabledByDefault`, `testOverExposedHubCanStillSendOut`,
    `testOverExposedSpokeRefusesInboundSends`).
16. A deposit past the cutoff is refundable until its epoch is cleared, and the
    refund is NAV-neutral: it reduces `cash` and `pendingDeposits` by the same
    amount, mints and burns nothing, and therefore changes neither `navBid` nor
    any rate. A redeem past the cutoff is never cancellable
    (`testCancelRulesAroundCutoff`, `testCancelAfterCutoffWhileFrozen`).
17. A Tick rejected on the spread bound consumes no rate-bucket capacity: the
    bucket level after the commit equals the level a plain time refill would have
    produced (`testSpreadRejectionSpendsNoBucket`).

---

## 16. Implementation phases (files)

| Phase | Deliverable | Files (planned) |
|---|---|---|
| 1 | Ticks | `contracts/tick/TickAccountant.sol`, `contracts/tick/NavSnapshot.sol` (types + encoding lib), `test/tick/*` |
| 2 | Epochs | `contracts/tick/EpochVault.sol`, `test/tick/EpochVault*.t.sol` |
| 3 | User protections | buffer, instant exit, caps in `EpochVault`; share-lock-negative tests |
| 4 | Cross-chain | `contracts/crosschain/ChainAgent.sol`, `IBridgeAdapter.sol`, `CctpV2Adapter.sol`, mock bridges (delayed, fee-charging, duplicate, malicious) |
| 5 | Rebalancer security | hardened `Rebalancer` generation (sandbox Findings 1–8 + provider caps + measured rebalance) |
| 6 | Transparency | events finalized, `docs/nav-reproduction.md`, reference snapshot builder (TS), `docs/epoch-benchmark.md` |
| 7 | Security testing | handler-based invariants 1–14, adversarial mocks, fork tests for CCTP V2 on Base/Arbitrum/Ethereum |

External audit is required before TVL for all of `TickAccountant`, `EpochVault`,
`ChainAgent` and `CctpV2Adapter`, the hardened `Rebalancer` diff, and the
snapshot spec together with its reference calculator.
