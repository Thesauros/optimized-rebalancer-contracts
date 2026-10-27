# Cross-chain threat model

Phase 0 deliverable. It covers the design in `docs/tick-accounting-design.md`
(section references like "§6.2" point there) and the current system in
`docs/current-architecture.md`.

## 1. Assets and trust boundaries

| Asset | Where |
|---|---|
| User principal and yield | Strategy `Rebalancer`s (Aave / Compound / Morpho) on each chain, agent idle balances, hub vault cash, CCTP in flight |
| Correct share price | `TickAccountant` rates |
| Exit liquidity | Hub vault free cash |
| Integrity of the public NAV | Snapshot calldata + `navHash` + reproducible rules |

| Party | Trusted for | Not trusted for |
|---|---|---|
| Governance (Safe-owned Timelock) | Configuration, after a public delay | Instant action |
| ADMIN (Safe) | Ratify/write down, unpause, roles, strategy fees and `Rebalancer.pause(Withdraw)` — all instant, no Timelock (T27–T29) | Configuration owned by the Timelock |
| NAV updater | Remote position values within corridor | Arithmetic, hub liabilities, shares (checked on-chain) |
| Executor | Choosing *when* and *how much* along fixed paths | Recipients, chains, adapters, amounts beyond buckets |
| Guardian | Stopping things | Starting things |
| Circle CCTP attesters | Authenticity of burn → mint | — (single external trust root of V1 transport) |
| Aave, Compound, MetaMorpho | Solvency of the supplied markets | — (inherited market risk) |
| ProxyAdmin owner | Everything (code replacement) | **Must be the Safe (SEC-001) before any TVL** |

The ceiling on every guarantee below is the ProxyAdmin owner and the Timelock
owner. A key that can swap the implementation bypasses every corridor.

## 2. Threats

Each row gives the scenario, what the design does about it, and what is left.

| # | Threat | Mitigation | Residual |
|---|---|---|---|
| T1 | **NAV updater compromised** | The rate moves only within the up/down buckets (rolling bound, §6.1). Beyond them the Tick quarantines and settles nothing. Arithmetic, hub cash, pending deposits, liabilities and shares are checked on-chain, so it cannot hide liabilities. Deposit clearing refuses Ticks that moved down more than `depositClearingMaxDown`. The guardian's only lever on the accountant is `freeze()`; **it cannot revoke the key** — `revokeRole` is `ADMIN_ROLE` only (`AccessManager.sol`), so removing the updater needs the Safe | Mispricing up to `capacity + refill · window` per direction before detection. Forced quarantine (DoS) |
| T2 | **Repeated valid-but-malicious updates** | Buckets are cumulative: the total over any window is at most `capacity + refill · W`. Per-update bounds alone (BoringVault) would compound; buckets do not | Slow drift at ≤ refill rate, which is the max believable APR. Detectable by any partner recomputing the snapshot |
| T3 | **Wrong NAV (honest bug)** | Same bounds as T1. The snapshot is public calldata, so any partner can diff it against chain state. Quarantine plus ratification | Error within the buckets until noticed |
| T4 | **Stale NAV** | Clearing and instant exits need `now − latestAccepted.committedAt ≤ maxTickAge`. Requests are still accepted (forward-priced). Clearing needs a Tick observed after cutoff | Liveness only |
| T5 | **Rebalancer (executor) compromised** | It can only call `allocate` / `deallocate` / `deallocateShares` on **the** configured `Rebalancer`, `bridgeOut` along Timelock-fixed routes to fixed peer agents, and vault ↔ hub agent with a buffer floor. Routes have per-transfer caps and daily volume buckets. `minReceive` has a floor of `1 − maxFeeBps`; `deallocateShares` has an executor-stated `minAssets` floor. Hub sends also require `chainSendAllowed(dst)`. Inside `Rebalancer`: listed providers only, per-provider caps, measured rebalance amounts | Misallocation within caps; bridge volume up to bucket capacity; fee leakage up to `maxFeeBps` per transfer. No theft path |
| T6 | **Bridge compromised (CCTP attesters)** | Out of our control. Bounded by the in-flight limit (route buckets) and the `Config.maxInFlightRatio` breaker: above it the accepted Tick carries `FLAG_IN_FLIGHT_LIMIT`, which stops hub sends. Note that flag does **not** block deposit clearing — only `FLAG_DOWN_BEYOND_DEPOSIT_LIMIT` and `FLAG_OVERDUE_IN_FLIGHT` do (`DEPOSIT_BLOCKING_FLAGS`) — so an in-flight overload halts new capital going out, not settlement. A forged mint can only *add* tokens to an agent, and only as authenticated by CCTP | Loss of in-flight funds, bounded by bucket capacity + refill · maxTransit |
| T7 | **RPC or indexer incorrect** | The snapshot pins `blockHash` per chain. On the hub the reference block must be within 256 blocks and its hash must equal `blockhash(n)`, checked on-chain at commit. A partner using independent RPCs detects divergence elsewhere | A wrong remote value from a bad RPC is bounded like T3. Run ≥ 2 independent RPC providers in the NAV engine and require them to agree |
| T8 | **Protocol adapter compromised** | Adapters are delegatecalled, so a malicious one equals full vault authority. Only the Timelock can add one (public delay). The hardened `Rebalancer` **tries** to revoke a removed provider's approval — the call is wrapped in `try this.revokeStaleApproval(...)` and on failure only emits `StaleApprovalRevokeFailed`, so a provider that reverts on approval changes keeps its unlimited allowance (removal still succeeds); it also keeps the entry provider listed, bounds provider views to `PROVIDER_VIEW_CALL_GAS`, refuses deposits while a view fails, and is `nonReentrant` | Governance/Timelock compromise. A stale approval that could not be revoked |
| T9 | **Delayed bridge** | In flight is valued at `minReceive` (bid) / `sent` (offer) while age ≤ `maxTransit`. Above `maxOverdueInFlight` the accepted Tick carries `FLAG_OVERDUE_IN_FLIGHT` (deployed threshold: 0), which blocks deposit clearing and hub sends. Nothing is paused and redemptions keep clearing at bid | Longer withdrawal latency if liquidity was in flight |
| T10 | **Lost bridge message** | CCTP burns are final and attestations are public and deliverable by anyone (permissionless `receiveBridge`). If it stays undelivered, it is overdue → ADMIN (Safe, no Timelock) calls `writeDown(id, loss, reason)`, which is an **advisory marker**: on-chain it only updates `_sent[id].writtenDown`, read by the `getSent` view, and it reaches NAV only if the NAV engine copies the same figure into `NavSnapshot.InFlight.writtenDown`. A late receipt books the recovery against the same id | Temporary under-recognition, never double-counting. The write-down and the snapshot are not bound on-chain |
| T11 | **Duplicate message** | CCTP nonce replay protection, plus `received[transferId]` set once in the agent | None identified |
| T12 | **Chain reorg** | The snapshot pins block hashes; a reorged reference makes the snapshot provably stale. Reference blocks should be **finalized** (Ethereum finalized checkpoint; L2 safe/finalized head). CCTP standard waits for source finality | A reorg of an L2 past its "safe" head: the engine must use finalized heads. Residual is equal to the chain's own finality assumption |
| T13 | **Destination chain unavailable** | Funds already there are `Position` entries (`KIND_IDLE` and `KIND_STRATEGY_SHARES`) in every snapshot and are validated as registered agents of that chain, so they are fully NAV-affecting. What an outage freezes is their **recognized value**: the engine cannot observe a new reference block for that chain, so the last observed value stands until it can. Missing data stops Ticks → stale → clearing waits (safe). Route buckets limit how much was sent there | Liveness; concentration on the unreachable chain is bounded only if `maxChainExposure` is enabled — it is implemented (`setMaxChainExposure`, `FLAG_CHAIN_EXPOSURE`, `chainSendAllowed`) but ships at `0`, i.e. **off**, because with two chains all capital starts on the hub and any cap below 100% would be breached on day one |
| T14 | **Protocol paused (e.g. Aave pool frozen)** | Position still valued (aToken balance) but not withdrawable. The withdraw loop skips failing providers (existing). Exits wait for other liquidity | Exit latency. Valuation does not haircut illiquidity in V1 (listed as a future valuation-rule change) |
| T15 | **Mass withdrawal** | Queue plus FIFO funding by epoch; exits never exceed liquidity; nothing is bridged synchronously for an instant exit. Price fixed at clearing at ≤ bid | Latency until recalls land. No insolvency path |
| T16 | **Mass deposit** | Pending cash is excluded from NAV until clearing. Minted at offer. Optional deposit cap per epoch | Dilution of yield (cash drag) until deployed, which is normal |
| T17 | **Flash-loan attack** | Minting happens at clearing only, never inside a flash loan. `instantRedeem` *does* redeem inside one transaction (see T18 — that is the backward-priced path), but not at a manipulable price: it pays the **stored** `rateBid` of the latest accepted Tick minus the fee, and no provider is read on that path, so borrowed funds cannot move the rate it uses. Provider valuations are not flash-manipulable either (aToken balance, Comet balance, Morpho `min(real, book)`), and they are read only by the off-chain engine at a pinned reference block | None identified from borrowing. The instant-exit timing risk is T18, not a price-manipulation risk |
| T18 | **MEV around a Tick update** | Forward pricing: queued requests are priced at a Tick after cutoff, so seeing the commit transaction in the mempool gives no edge for queued flows. The only backward-priced path is instant exit: capped per call and per day, fee-charged, fresh-Tick-only (enabled with limits by founder decision). A pending `commitTick` is public calldata, so its rate is known before it lands; exiting just ahead of a Tick that books a loss avoids that loss and costs only `instantFee`. The front-run therefore pays exactly when the loss can exceed the fee, and the largest loss one **accepted** Tick can book is the down bucket's capacity. That gives the calibration rule `instantFee >= downBucket.capacity`, enforced by an assertion in `registry.ts` (0.25% fee against a 0.2% bucket), checked at deploy and continuously by the monitor, and demonstrated both ways by `AdversarialScenarios.t.sol::testInstantFeeMustCoverTheDownBucket` | Instant exit up to the daily cap × the upcoming move, net of the fee, whenever the calibration holds. A Tick outside the bucket quarantines instead, which removes the priced move altogether |
| T19 | **MEV around epoch clearing** | Clearing is deterministic and permissionless; the price does not depend on who calls or in what order. Claims are FIFO by epoch, not by caller. Cancellation after the cutoff is limited to a **deposit** whose epoch is not cleared yet; a refund of pending deposits is NAV-neutral, so it carries no option value. A redeem can never be cancelled past the cutoff, which is where the option value would be | None identified |
| T20 | **Deposit front-running a favourable Tick** | Priced at that Tick (forward pricing) at offer | None |
| T21 | **Withdrawal front-running an unfavourable Tick** | `min(open, clear)`: a loss booked before clearing is borne by the exiting request. Instant exit is bounded as in T18, and is priced by the same rule `instantFee >= downBucket.capacity` | Loss unobservable at the reference time (design §5.6) |

### Added after implementation

| # | Threat | Mitigation | Residual |
|---|---|---|---|
| T22 | **Donation to an agent to force quarantine** (inflate idle beyond the up bucket) | Donations are real value and are counted once. A large one quarantines until the next in-bounds Tick or ratification; nothing mis-settles | Liveness griefing that costs the attacker the donated amount, which accrues to holders. Because the donation persists, no later Tick is in bounds and the move is upward, so it resolves only by a Timelock `ratifyTick`: settlement (clearing, instant exits, hub sends) halts for the Timelock delay, 24 h in production. The cost is the up-bucket capacity, 0.5% of NAV; deposits remain refundable meanwhile through `cancel` |
| T23 | **Request spam to block Tick commits** | Hub binding uses per-block checkpoints with an index hint, not "no change since the reference block", so requests cannot invalidate a snapshot | None identified |
| T24 | **Slow updater misses the 256-block window** | The commit reverts; the updater retries with a fresher snapshot | Liveness only; a stale Tick blocks clearing and instant exits, never mis-prices |
| T25 | **Spoke breaker lag** | Spokes cannot read the hub accountant; the guardian pauses spoke agents and disables routes, both instant | Human reaction time on spokes; hub sends stop automatically |
| T26 | **Adapter delivers funds outside the agent** (unrecorded mint would be counted twice) | `IBridgeAdapter`'s "agent-only `finalize`" is **NatSpec, not an enforcement** — an interface comment binds nothing. What actually enforces it is each adapter's own code: `CctpV2Adapter.finalize` carries `onlyAgent`, CCTP checks `destinationCaller` = the peer adapter, `mintRecipient` must equal our agent, and the source adapter is authenticated via the burn's `messageSender` (tested against a real CCTP V2 message on a Base fork). A future adapter must repeat all of it itself | Adapter code bugs; needs audit. A Timelock-appointed malicious adapter is a governance-trust matter, not something the interface prevents |
| T27 | **ADMIN blocks all exits without a Timelock** | `ChainAgent.deallocate` / `deallocateShares` have no agent pause domain, but they call `IERC4626.withdraw` / `redeem` on the strategy, and the strategy is a `Rebalancer` whose `_validateWithdraw` is `whenNotPaused(Actions.Withdraw)`. `Rebalancer.pause` is `ADMIN_ROLE` with **no Timelock**, so one Safe transaction stops deallocation, which stops recalls from spokes, which stops epoch funding, which stops every queued redemption. `EpochVault.cancel` has no pause domain, so a deposit is still refundable until its epoch clears | ADMIN (Safe) compromise or coercion halts withdrawals instantly, with no public delay to react to. The monitor raises `strategy.<chain>.paused` as critical whenever a strategy's Withdraw action is paused |
| T28 | **ADMIN re-prices the vault via `ratifyTick`** | `ratifyTick(tickId)` makes the latest quarantined Tick settle-able, charges no fee on it, does not raise the high-water mark and does not consume bucket capacity. It is split by direction: a Tick whose bid rate is at or below the last accepted one (a loss) is ADMIN-instant, so real losses are recognised without delay; an upward re-pricing requires the Timelock. A loss cannot drain remaining holders — redemptions pay `min(openRateBid, rateBid)` and a down-move beyond `depositClearingMaxDown` cannot clear deposits | ADMIN can still book a false loss instantly, which harms the epoch's redeemers, not the remaining holders; an upward re-pricing is public for the Timelock delay. The upward corridor itself has an absolute ceiling (`MAX_UP_CAPACITY` 2%, `MAX_UP_REFILL_PER_SECOND` 100%/year) that no Timelock action can lift |
| T29 | **ADMIN grants itself every operational role** | `AccessManager` has no role admins: `grantRole`/`revokeRole` are `ADMIN_ROLE` and grant anything, so the Safe can give itself `NAV_UPDATER_ROLE`, `EXECUTOR_ROLE` and `GUARDIAN_ROLE` on the accountant, the vault and every agent | Key separation between governance and operations is an operational promise, not an on-chain invariant |

### Countermeasures considered and not adopted

* **Share lock** (restricting transfers of queued or freshly minted shares). Not
  adopted; it is redundant, and `docs/tick-accounting-design.md` D10 / §8.5
  carries the proof: the only mint path is clearing at `rateOffer ≥ R`, the only
  exits are the forward-priced queue at `≤ rateBid` and the capped instant exit at
  `≤ rateBid · (1 − fee)`, and transfers change who holds a share, not the price
  it was minted at or can exit at.
* **Commit/reveal for Ticks.** Considered and rejected. Its only purpose here
  would be to hide a pending `commitTick` from the instant-exit front-run of T18,
  and that front-run is already priced: `instantFee >= downBucket.capacity` makes
  exiting ahead of the largest loss one accepted Tick can book a net loss for the
  exit. Commit/reveal would add a two-phase commit, a reveal deadline and a new
  liveness failure to the updater, to close a corridor the fee already covers.
* **Delayed Tick activation.** Not needed for the same reason: queued flows are
  forward-priced at a Tick observed after the cutoff, so activation delay would
  only add latency to clearing.

## 3. Live risk found during Phase 0

The legacy `CrossChainVault` on Base mainnet is at
`0x8AD87BB0FE973A48e5C027E1C27A708BBe78a8Ae`, from the separate repository
`thesauros.io/contracts`, branch `crosschain`. This is finding SEC-018.

* **State.** `totalAssets` is 0.200470 USDC, against 3.900470 USDC actually
  held. The 3.7 USDC Allocate was moved out of the ledger by keeper status flags
  and never dispatched.
* **Exposure.** Deposits are still open with unlimited `maxDeposit`.
  `previewDeposit(1 USDC)` returns about 24.4 shares, so a new depositor would
  receive a claim on most of the stranded 3.9 USDC.
* **Why it has not been drained.** Withdrawals are currently blocked because the
  reports are stale.
* **Pre-condition for any repair.** Any accounting repair that restores the
  ledger would hand the gap to whoever deposited in between. **Pause deposits
  there before any repair.**
* **Scope.** This is an operational action with the deployer key and is outside
  this repository. It is recorded here because this initiative found it.

Observation source: read-only public RPC and explorer data, 2026-09-27, gathered
during the Phase 0 analysis. It should be re-verified immediately before acting.

## 4. Cross-cutting prerequisites (not solvable in contracts)

1. **SEC-001 closed** for every new proxy: the ProxyAdmin is owned by the Safe from
   deployment, and no EOA holds any role.
2. **SEC-002:** the plaintext deployer key is rotated. The NAV updater and executor
   keys are distinct from each other and from any governance key.
3. **NAV engine:** at least two independent RPC providers per chain, finalized
   heads only, and a published snapshot for every Tick.
4. **Monitoring:** Timelock queue, bucket levels, in-flight ages, quarantine
   events, and the per-chain/per-protocol exposure versus caps. Note that with
   `maxChainExposure = 0` there is no per-chain cap to compare against at launch,
   so per-chain exposure has to be watched against the intended allocation
   instead; phase 4 and the monitor report the current cap value
   (`ops/src/checks/deployment.ts`) and alert on `PauseSet` in every strategy
   `Rebalancer` (T27).

## 5. Bridge options: security differences, kept explicit

| | CCTP V2 (V1 choice) | LayerZero OFT / Stargate | Chainlink CCIP | Hyperlane |
|---|---|---|---|---|
| Asset model | Native USDC burn/mint | Pool (Stargate) or OFT mint | Lock/mint or burn/mint per token pool | Warp routes |
| Authenticity root | Circle attesters | Configured DVN set + executor | DON + risk management network | Configured ISM |
| Liquidity/slippage risk | None | Pool depth (Stargate) | Pool limits | Route dependent |
| Amount received | = burned (standard); − fee ≤ `maxFee` (fast) | Can be < sent (fees, slippage) | Fees in LINK/native; token amount exact | Route dependent |
| Destination restriction | `destinationCaller` + `mintRecipient` | Peer config | Receiver contract | Recipient |
| Supports carrying our id | `hookData` | Compose message | Data payload | Message body |

Core accounting depends only on `(transferId, measured received)`. Any second
adapter needs its own threat-model row above before it is enabled.

## 6. Components requiring external audit

`TickAccountant`, `EpochVault`, `ChainAgent`, `CctpV2Adapter`, the hardened
`Rebalancer` diff (sandbox Findings 1–8 + provider caps + measured rebalance),
and the snapshot specification together with its reference calculator (a spec
bug is a NAV bug).
