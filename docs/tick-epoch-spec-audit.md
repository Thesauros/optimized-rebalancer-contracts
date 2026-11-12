# Tick/Epoch spec audit

Independent audit of `feat/crosschain-tick-epoch` against
`thesauros_tick_epoch_prompt_ru.md` (38 sections, 14 core invariants, the V1
list and the final-report list). Written 2026-09-28 after the branch was
complete and rehearsed, so this is a check of the as-built system, not a design
review.

Method: every contract read in full; the CCTP V2 assumptions checked against
Circle's own source at the commit the adapter cites; the off-chain snapshot
builder checked field by field against the on-chain validator; the whole suite
run. Findings that were unambiguous defects are fixed in the same pass and
marked FIXED with the test that pins them. Findings that are genuine design
trade-offs are marked DECISION and are not changed unilaterally.

Companion documents: `tick-accounting-design.md` (design),
`implementation-report.md` (as built), `cross-chain-threat-model.md` (threats),
`epoch-benchmark.md` (cadence), `nav-reproduction.md` (independent NAV),
`crosschain-limits.md` (every parameter), `crosschain-open-items.md` (what is
not built).

---

## 1. Verification actually performed

| Check | Result |
|---|---|
| `forge build --force contracts` | clean, zero warnings from any file in `contracts/` (the 256+ warning aggregate comes from `lib/forge-std`; solc truncates it to a single diagnostic with no source location, so `ignored_warnings_from` cannot filter it) |
| `forge test --no-match-path "test/forking/*"` | all pass, including 6 invariant handlers at 256 runs x 500 calls |
| `forge test --match-path "test/forking/*"` | all pass except `NewVaultWithdraw.t.sol`, which needs a hand-set `VAULT` env var and contains no assertions; it is a manual trace harness, not a regression |
| `ops` tests | all pass, including the ABI drift guard against the compiled artifacts |
| `tsc` (repo and `ops`, strict) | clean |
| Snapshot encoding, Solidity vs TypeScript | identical hash pinned on both sides (`SnapshotVector.t.sol`, `ops/test/snapshot.test.ts`) |
| CCTP V2 message layout | byte offsets verified against `circlefin/evm-cctp-contracts` at `a92a2b4`: `MessageV2.MESSAGE_BODY_INDEX = 148`, `SOURCE_DOMAIN_INDEX = 4`, `BurnMessage.MINT_RECIPIENT_INDEX = 36`, `MSG_SENDER_INDEX = 100`, `BurnMessageV2.HOOK_DATA_INDEX = 228`. The adapter's constants match all five |
| CCTP V2 `destinationCaller` | enforced in `MessageTransmitterV2._validateReceivedMessage`; combined with `onlyAgent` on `finalize` and `mintRecipient == agent`, no mint can reach an agent unrecorded |
| CCTP V2 hook | `TokenMessengerV2._handleReceiveMessage` mints and does not call the recipient. `hookData` is a data payload only, so no `IMintHookReceiver` is needed and none is implemented. This was verified rather than assumed |
| Fee mint arithmetic | `feeShares = supply * fee / (navBid - fee)` re-derived: it is exactly the dilution that makes the post-mint rate equal the stored net rate |
| Deposit clearing at the offer rate | proven non-dilutive: `(nav + D) / (S + D / rateOffer) >= nav / S` whenever `rateOffer >= navBid / S`, which `navOffer >= navBid` guarantees |
| Not deployed | `deployments/*/crosschain.json` does not exist, so nothing in this branch is on mainnet. The August artifacts under `deployments/` are the legacy single-chain vaults |

---

## 2. Compliance with the 38 sections

Status: MET, PARTIAL (met with a documented deviation), or GAP.

| Section | Requirement | Status | Evidence |
|---|---|---|---|
| 0 | Analyse `dev` before implementing; produce `current-architecture.md` and `tick-accounting-design.md`; prefer extension over replacement | MET | Both documents exist. `AccessManager`, `Timelock`, `PausableActions`, the three providers, `ProviderManager`, `VaultFactory`, `ProxyImports` and `Constants` are byte-identical to `dev`; only `Rebalancer.sol`, `IRebalancer.sol` and `network-config.ts` were modified. BoringVault was used as a reference and explicitly not copied |
| 1 | Tick = confirmed snapshot of all accounting-relevant state | MET | `ITickAccountant.Tick`, `TickCommitted` |
| 2 | Minimal on-chain Tick; monotonic id; timestamp; committed NAV and rate; commitment to the full snapshot; provable state per operation; accepted Ticks not rewritable | MET | Fields differ from the brief's sketch deliberately, as the brief allows: dual `rateBid`/`rateOffer` instead of one `accountingRate`, plus `status`, `flags` and `hubBlock`. Only Quarantined -> Ratified ever mutates a stored Tick |
| 3 | NAV computed off-chain, independently reproducible, no opaque oracle | MET | `ops/src/nav.ts`, `ops/src/snapshot.ts`; every input is a public `eth_call` or an event; `ops/src/verify-tick.ts` re-derives any Tick from calldata |
| 4 | Canonical machine-readable snapshot; deterministic encoding, not JSON; `navHash` stored in the Tick | MET | `NavSnapshot`: ABI-encoded, `VERSION = 1`, strict ordering on all three arrays (which also rejects duplicates), rates derived rather than supplied so a snapshot cannot carry a rate contradicting its own positions |
| 5 | Conservative accounting; distinguish economic, recognized and effective NAV; never distribute unrecognized value | MET | Bid/offer dual pricing (`tick-accounting-design.md` §4.1-4.2). Bid values every uncertain item at its lowest plausible value and prices exits; offer prices entries. Effective NAV is bid net of on-chain fees |
| 6 | Formal `depositPrice` / `withdrawalPrice`; analyse `max(old,new)` and `min(old,new)` but do not apply them without proof | MET | Deposit = offer at the clearing Tick. Withdrawal = `min(bid at epoch open, bid at the clearing Tick)`. `max()` was analysed and rejected with reasons: forward pricing already removes the timing gain, and `max()` would charge a depositor for a loss their pending cash never bore |
| 7 | Do not confiscate user value; pick a deterministic fate for unrecognized value | MET | Model 1 of the brief: unrecognized positive value is recognized in a later Tick and accrues to whoever holds shares then. Bounded by the spread plus epoch-length yield, stated to users, never silent |
| 8 | Tick vs Epoch separation; hybrid `minTicks` / `maxEpochDuration`; do not hardcode 10 | MET | `closeEpoch` when `(elapsed >= minDuration && ticks >= minTicks) || elapsed >= maxDuration`, all Timelock-configurable |
| 9 | Epoch duration configurable, benchmarked | MET | `epoch-benchmark.md`. Nothing is hardcoded; `setEpochConfig` is `onlyTimelock` |
| 10 | Epoch clearing: accepted Tick, effective NAV, settlement, mint/burn or claims, carry-forward | MET | `clearDeposits`, `clearRedeems`, `fund`, `claim`, all permissionless and deterministic. Deposits and redeems have independent cursors, so a Tick unusable for entries still settles exits |
| 11 | Deposit flow pending -> epoch -> conservative price -> shares/claim; no `deposit -> observe NAV -> redeem` profit | MET | `pendingDeposits` is excluded from NAV, so pending cash bears no P&L. `AdversarialScenarios.testDepositAroundPositiveTickIsNotProfitable` proves the round trip does not profit whether the deposit lands one block before or after a known favourable Tick |
| 12 | Evaluate `shareLockPeriod`; check bypasses; do not add it if epochs make it redundant, but prove that | MET | Not added, with the proof in `tick-accounting-design.md` §8.5: the only mint path is clearing at `rateOffer >= R`, the only exits are the forward-priced queue at `<= rateBid` and the capped, fee-charged instant exit, and transfers change who holds a share, not the price it was minted at or can exit at. Negative tests cover transfers, second accounts and repeated deposits |
| 13 | Withdrawal flow with remote liquidity not required synchronously; store requestId, user, receiver, shares, requestedTick, requestedEpoch, minAssets/maxLoss, status | PARTIAL | States REQUESTED, CANCELLED and CLAIMED are stored; CLEARED, QUEUED, LIQUID and CLAIMABLE are derived from epoch state; EXPIRED is deliberately unused because an owed exit must stay payable. Deviations: `requestedTick` is stored per epoch (`openTickId`) rather than per request, and per-request `minAssets`/`maxLoss` do not exist — a per-request floor cannot coexist with O(1) batch clearing, so it is replaced by a protocol-level bound (the down bucket capacity, beyond which the Tick quarantines) plus `minAssets` on the instant path. Reasoning in `tick-accounting-design.md` §5.3 |
| 14 | Withdrawal price: compare fixed, clearing, `min`, epoch-only, base-plus-adjustment | MET | All five compared; epoch price `min(open, clear)` chosen. Consequences stated to users: yield stops at epoch open, and the maximum loss while queued is the down bucket capacity |
| 15 | Local buffer with `targetBufferRatio`, `minimumBuffer`, `maximumInstantWithdrawal`, `dailyInstantWithdrawalLimit`; instant for small, queue for large; never bridge synchronously for an exit | MET | `Limits.minimumBuffer`, `minBufferRatio`, `maxInstantWithdrawal`, `dailyInstantLimit`; `minimumBuffer()` = `max(minimumBuffer, minBufferRatio * navBid)`. No bridge call exists anywhere on the instant path. `AdversarialScenarios.testMassWithdrawalExceedsBuffer` |
| 16 | Rebalance state machine with `rebalanceId`, source/destination chain and protocol, asset, amount, bridge, messageId, timestamps, status | PARTIAL | `rebalanceId` exists but is a free-form executor label with no uniqueness check, and only `BridgeOut` carries it. `Allocated` and `Deallocated` carry neither id, `SOURCE_LIQUID` and `CANCELLED` are not events, `BRIDGE_INITIATED` and `FAILED` do not exist (CCTP has no failed terminal: a burn is final, so "failed" means "not yet minted"), and neither the CCTP message id nor a protocol field is recorded. The deliberate design is that every accounting fact is an event of a measured token movement and the composite state is derived off-chain; the cost is that five of the eleven depicted states cannot be joined to a `rebalanceId` on-chain. See §5 below |
| 17 | In-flight accounting; one asset in exactly one state; invariant test | MET | The consistent-cut rule (`tick-accounting-design.md` §4.3) makes double counting impossible for a correct builder, and `CrossChainInvariants.invariant_singleState` asserts it over 128k fuzzed calls. The cut itself is enforced off-chain: no contract can verify a remote chain's block, so a dishonest builder could double-count, bounded by the up bucket |
| 18 | Do not assume `sent == received`; classify the difference; conservative valuation until confirmed | MET | Receipt is a measured balance delta. Bid carries `minReceive`, offer carries `amountSent`, so the shortfall is recognized at receipt and the difference is visible in the next Tick. `writeDown(transferId, amount, reason)` records a governance loss estimate — see §4, finding W1: it is advisory to the NAV engine and has no on-chain accounting effect |
| 19 | Accountant-like NAV update module with monotonic id and timestamp, minimum interval, maximum age, max up/down movement, cumulative constraints; reject and/or break | MET | `commitTick` in order: role, vault bound, identity and time, encoding, membership, hub binding, arithmetic, spread, buckets, risk flags, fees, store. Out of bounds is stored as Quarantined rather than reverted, so a real loss is never discarded — reverting would keep paying exits at the pre-loss price |
| 20 | Rate corridor; per-Tick bound insufficient against a series of valid moves; consider per-Tick, per-Epoch, per-24h and rolling limits; all configurable | MET | Token buckets per direction. Total movement in one direction over any window W is at most `capacity + refill * W`, which is a true rolling bound in two storage slots and covers all four named limits in O(1). `testFuzzCumulativeUpBound`, `testManySmallUpMovesExhaustTheBucket` |
| 21 | Circuit breakers with granular pause domains, not one global pause | MET | Six vault domains, two agent domains, plus freeze/quarantine on the accountant and three Tick flags. Claims of funded exits, cancels, deallocations, recalls and CCTP deliveries are never pausable, by design |
| 22 | Rebalancer must not have arbitrary control of TVL; Merkle manager only as reference; constrain target, selector, args, asset, chain, recipient, amount; forbid arbitrary calls | MET | No Merkle manager: the action space is small and enumerable, and Veda's leaves contain only addresses and `valueNonZero`, so it would not give amount limits anyway. Same chain: provider whitelist plus per-provider caps. Cross-chain: fixed routes (adapter, chain, peer agent) with `maxPerTransfer`, a volume bucket and a `minReceive` floor. The executor cannot name a recipient, an adapter or a chain. Caveat: caps default to 0 = uncapped and `AaveV3` ships uncapped — DECISION D6 |
| 23 | Configurable `maxInFlightAssets`, `maxInFlightPercentage`, `maxBridgeTransaction`, `maxDailyBridgeVolume`, `maxChainExposure`, `maxProtocolExposure`; hardcode nothing | PARTIAL, now improved | `maxBridgeTransaction` = `Route.maxPerTransfer`; `maxDailyBridgeVolume` = the route volume bucket (per route, not global); `maxInFlightPercentage` = `Config.maxInFlightRatio`; `maxChainExposure` = FIXED today (§4, F3). Still absent: an absolute `maxInFlightAssets`, and a global `maxProtocolExposure` (protocol exposure is bounded per chain by `Rebalancer` caps, not across chains). Nothing is hardcoded |
| 24 | Bridge adapters allowing future CCTP, LayerZero, Hyperlane, CCIP; one bridge is enough for V1; do not hide security differences behind a generic interface | MET | `IBridgeAdapter` has two functions and exposes only transfer ids and measured balances. Security differences stay explicit per adapter in the threat model §5. Core accounting has no CCTP dependency |
| 25 | Contracts and events sufficient for a public dashboard: recognized NAV, current Tick/Epoch, rate, last update, positions per chain and protocol, idle, in-flight, pending | MET | `accounting()`, `cursors()`, `getEpoch`, `getRequest`, `getTick`, `latestAccepted`, `buckets()`, `getRoute`, `getSent`, `getReceived`, plus `TickCommitted`, `BridgeOut`/`BridgeIn`/`WrittenDown` and the full request and epoch event set. `ops/src/indexer.ts` serves it |
| 26 | `nav-reproduction.md` with per-protocol valuation, queried contracts, reference blocks, accrued yield, debt, rewards, in-flight treatment; independent calculator reaching the same hash | MET | The document matches the code on every protocol (Aave aToken balance, Comet balance, Morpho `shares * min(real, book) / (totalSupply + pendingFeeShares)`), and the same hash is pinned on both sides of the language boundary. Weaker than documented in one respect: the monitor re-derives only the latest accepted Tick and caches the verdict, so a Tick verified once is never rechecked and Ticks missed while the monitor was down are never verified |
| 27 | `epoch-benchmark.md` comparing every Tick / 5 / 10 Ticks / 30 min / 6 h / 24 h as researched variants, not defaults, across ten named axes | PARTIAL | Being corrected: three of the six cadences were missing, Ethereum finality and rebalance duration were absent, withdrawal latency was not separated from deposit latency, and yield volatility was conflated with yield forgone |
| 28 | Tick frequency independent of Epoch frequency | MET | Ticks land on the NAV service cadence; settlement only at epochs. `minTicks` couples them only as a floor |
| 29 | `cross-chain-threat-model.md` covering all twenty named threats | MET | All twenty have a row, plus five the brief did not ask for. Several named mitigations were aspirational rather than implemented and are being corrected — see §4 |
| 30 | MEV around Ticks; knowledge of a future Tick must not create risk-free arbitrage | MET after fix | Forward pricing removes the epoch path. The residual is the instant exit, which is backward-priced by construction and was exploitable while `instantFee < downBucket.capacity` — FIXED today (§4, F2), with a test that demonstrates both the vulnerable and the corrected configuration. Share lock rejected with a proof; commit/reveal considered and rejected because the fee now covers the corridor |
| 31 | The fourteen core invariants | See §3 | |
| 32 | Adversarial mocks: MaliciousNAVUpdater, MaliciousRebalancer, MaliciousBridge, DelayedBridge, FeeChargingBridge, DuplicateBridgeMessage, ReentrantReceiver | PARTIAL | Present by behaviour rather than by name: three malicious adapters (short-pulling, forging, bare EOA), a delayed bridge by construction, a fee knob, a duplicate-delivery knob and a re-entrant adapter. A malicious NAV updater is modelled by tampering with an honest snapshot from the updater key rather than by a contract, which is equivalent. GAP: no test installs a malicious strategy into `ChainAgent`, so invariant 7 is proven for the bridge leg only |
| 33 | Reuse the access model; document allowed, prohibited and worst-case per role; timelock high-risk config; keep emergency pause fast | PARTIAL | `ADMIN`, `EXECUTOR`, `NAV_UPDATER`, `GUARDIAN` exist; `PAUSER` is folded into `GUARDIAN` and `EPOCH_SETTLER` does not exist because clearing is permissionless — both correct decisions that the docs did not record. Worst-case compromise is documented for the NAV updater and the executor only. High-risk config is timelocked except for the ADMIN powers listed in DECISION D1-D5 |
| 34 | Phases 0-7 | MET | All eight phases delivered, in order, with the files the plan named |
| 35 | Minimum V1: the thirteen listed properties | MET | All thirteen exist. Transparent global NAV, Tick state, configurable epoch clearing, conservative settlement, stale-NAV protection, withdrawal queue, liquidity buffer, cross-chain rebalance state machine, in-flight accounting, constrained rebalancer, bridge limits, public NAV hash, reproducible accounting |
| 36 | Final architectural principle | MET | Hub-and-spoke, off-chain NAV calculator, on-chain accountant, epoch clearing, allocator -> rebalancer -> policy layer, every cross-chain transition explicit. No synchronous global state anywhere |
| 37 | Final economic principle: temporary under-recognition acceptable, overpayment or insolvency not; under-recognized value must have a deterministic fate | MET | Enforced by bid/offer, forward pricing, `min(open, clear)`, quarantine instead of revert, and `invariant_conservation` plus `invariant_vaultSolvency` over 128k fuzzed calls |
| 38 | Final report with 25 named items including three Mermaid diagrams | MET with corrections | `implementation-report.md` carries all 25 items and all three diagrams. The architecture diagram shows an Ethereum spoke that is not in the registry, and the state-machine diagram depicts states that are not reconstructible from events; both being corrected |

---

## 3. The fourteen core invariants (section 31)

| # | Invariant | Enforced by | Tested by |
|---|---|---|---|
| 1 | Never distribute more than safely recognized value | Bid pricing on every exit; `navBid` reverts if liabilities exceed assets | `invariant_vaultSolvency`, `invariant_conservation`, `invariant_ticksAndPricing`, `testMassWithdrawalExceedsBuffer` |
| 2 | Uncertainty delays recognition, never creates insolvency | Quarantine instead of revert; pending deposits excluded from NAV | `testLargeLossIsQuarantined`, `testBridgeDelayedAcrossTicksAndEpochClearing`, `invariant_vaultSolvency` |
| 3 | One economic asset never in two accounting states | Consistent cut, in-flight booked separately from positions | `invariant_singleState`. Residual: nothing ties a committed `navBid` to the real measured token total, because the snapshot is built by the same reference engine the handler trusts |
| 4 | Tick ids monotonic | `tickId == lastTickId + 1` | `testTickIdMustBeSequential`, `invariant_ticksAndPricing` |
| 5 | Accepted Tick immutable | Append-only mapping; only Quarantined -> Ratified | `testRatifyMakesLargeRealMoveSettleable`, re-commit and struct-hash checks |
| 6 | A cross-chain operation never completes twice | `received[transferId]` set once, plus the CCTP nonce | `testDuplicateDeliveryRejected` (wire topped up so it really could pay twice), `invariant_singleState` |
| 7 | A compromised rebalancer cannot send to an arbitrary recipient | No recipient parameter anywhere; routes fixed by the Timelock and permanent; measured debits | Bridge leg: `testExecutorCannotChooseRecipientOrRoute`, `testRouteEndpointsArePermanent`, `testShortPullingAdapterIsRejected`, `testForgedSourceIsRejected`. GAP: no malicious strategy is ever installed into a `ChainAgent` |
| 8 | Bridge exposure never exceeds limits | `maxPerTransfer`, volume bucket, `minReceive` floor, `maxInFlightRatio` | `testMaxPerTransfer`, `testRouteVolumeBucket`, `testMinReceiveFloorFromFeeCap`, `testHubSendsHaltOnInFlightLimitFlag` |
| 9 | Stale NAV cannot be atomically arbitraged deposit -> redeem | Forward pricing; the instant path is capped, fee-charged and requires a fresh unfrozen Tick | `testDepositAroundPositiveTickIsNotProfitable`, `testInstantCannotJumpTheQueue`, `testClearingRefusesStaleTick`, `testInstantRequiresFreshUnfrozenTick` |
| 10 | The NAV updater cannot leave the rate corridors | Buckets per direction, measured against the last ACCEPTED rate, so a quarantined move is not laundered | `testOverstatedRemoteValueIsQuarantinedNotSettled`, `testSpreadBound`, `testManySmallUpMovesExhaustTheBucket`, `testCompromisedUpdaterExtractionIsBounded` |
| 11 | Cumulative limits cannot be bypassed by a series of valid updates | `capacity + refill * W` bound | `testFuzzCumulativeUpBound` (256 runs). Note the assertion carries a 2% tolerance for compounding; the direction is conservative but the slack is real |
| 12 | A withdrawal cannot be settled twice | Status transitions plus a single `funded` flag per epoch | `testClaimTwiceReverts`, `invariant_claimOnce` |
| 13 | Shares and claims stay consistent after clearing | Aggregate floor at clearing, per-request floor at claim, so claims never exceed what was minted or reserved | `invariant_shareBookkeeping`, `testDepositMintsAtClearingOfferRate`. Residual: per-request flooring leaves dust in `reserved` and `liabilities` permanently — see D9 |
| 14 | Pause blocks the corresponding risk-taking operations | Six vault domains, two agent domains | `testEveryPauseDomainBlocksItsOwnOperation` (all six, against a live queue), `testDeallocateNeverPaused`, `testBridgeOutPauseBlocksSendsNotReceipts`, `testFundedClaimsAndCancelsSurviveEveryPause`. Residual: no pause or freeze action is fuzzed in the invariant handler |

---

## 4. Findings fixed in this pass

Each was confirmed by reading the code, not inferred. "Pinned by" names the test
that fails if the fix is reverted.

| # | Finding | Why it mattered | Fix | Pinned by |
|---|---|---|---|---|
| F1 | `commitTick` tested the corridor before the spread bound, and `_consumeBuckets` spends rate capacity. A Tick rejected on spread was quarantined AND had already drained the bucket | Capacity was destroyed without the accepted rate moving, so the next honest Tick could quarantine too and stall all settlement until the bucket refilled (0.1%/day downward) | Spread bound first; the bucket is now untouched, not even refilled, on a rejected Tick | `testSpreadRejectionSpendsNoBucket` |
| F2 | `instantFee` (0.1%) was below `downBucket.capacity` (0.2%) | A pending `commitTick` is public calldata, so its rate is known before it lands. Exiting just ahead of a Tick that books a loss avoided the loss and cost only the fee: risk-free profit up to `dailyInstantLimit x (capacity - fee)`, a direct violation of section 30 | Fee raised to 0.25%, the relation derived as a constant in `registry.ts`, asserted at module load, and checked on-chain in phase 4 and continuously by the monitor | `testInstantFeeMustCoverTheDownBucket`, which demonstrates the profit under the old configuration and its absence under the new one |
| F3 | No per-chain exposure cap existed anywhere, while the design document claimed `commitTick` detected it and the threat model relied on it as a mitigation | Section 23 requires `maxChainExposure`. Route buckets bound flow, not stock, so the executor could concentrate all TVL on one chain over time | `maxChainExposure` implemented: derived per Tick in `NavSnapshot.chainBids`, stored per chain, exposed as `FLAG_CHAIN_EXPOSURE` and `chainSendAllowed(dst)`. It blocks sends INTO an over-cap chain and never blocks sends out of it or settlement. The denominator is gross bid assets, not NAV — netting off pending deposits and liabilities would push every chain's apparent share past 100% during a large deposit or redemption epoch and latch the flag for a reason unrelated to concentration. Deliberately outside `Config`, so no existing `setConfig` caller changed. Ships disabled (0) with the reason recorded | `testChainExposureDisabledByDefault`, `testChainExposureCapRejectsAboveWad`, `testOverExposedHubCanStillSendOut`, `testOverExposedSpokeRefusesInboundSends`, and `testChainExposureUsesGrossAssetsNotNav`, which fails if the denominator is switched back to NAV |
| F4 | `maxClearingDelay` (1 h) was shorter than `maxTickAge` (2 h) | `_usableTick` enforces both. A NAV service committing every 1-2 h looked healthy to the staleness breaker while every `clearDeposits` and `clearRedeems` reverted `TickNotUsable` forever, and `bridgeSendsAllowed` stayed true, so nothing signalled the deadlock | `maxClearingDelay` derived as `maxTickAge + maxSnapshotAge + 15 min`, asserted at module load, checked in phase 4 and by the monitor | `checks/deployment.ts` |
| F5 | `maxSnapshotAge` was 10 min against a hard 256-block hub window of about 8.53 min on Base | The configured value was unreachable: a snapshot aged 8.53-10 min passed the age check and then failed `InvalidHubReference`, which does not distinguish stale from reorged from wrong checkpoint | 8 min, derived from `256 x hubBlockTime`, asserted at module load, checked in phase 4 | `checks/deployment.ts` |
| F6 | A deposit in an epoch that closed while the accountant was frozen or quarantined had no exit: clearing needs a usable Tick, and `cancel` required an open epoch | User funds locked indefinitely by any incident long enough to span an epoch, with recovery gated on a 2-of-2 Safe | A deposit may now be cancelled after the cutoff until its epoch is deposit-cleared. This is exactly NAV-neutral, because pending deposits are excluded from NAV, so no price changes and nobody can use it to leave at a pre-loss rate. A redemption stays non-cancellable past the cutoff: its price is only fixed at clearing, so a late cancel would be a free option on the epoch's yield at the remaining holders' cost | `testCancelRulesAroundCutoff`, `testCancelAfterCutoffWhileFrozen`, and the invariant handler's `cancelLatest` now fuzzes the new path under `invariant_conservation` |
| F7 | `_validateMembership` checked only the agent mapping, not the chain set | A chain dropped from the set while its agents stayed marked could carry a position that `totals()` counted but `chainBids()` could not see, so exposure would be understated | Positions on an unlisted chain now revert `UnknownChain` | `testPositionOnUnlistedChainRejected`, which drops the spoke from the chain set, shows its agent mark survives, and proves its balance is still reported as a position |
| F8 | `deallocateShares` had no floor, unlike `deallocate`, which enforces exactness | A strategy returning less than expected on `redeem` was undetected at the agent level | `deallocateShares(shares, minAssets)` with a new `SlippageExceeded` error; the amount is still measured | `testDeallocateSharesEnforcesFloor` |
| F9 | Invariant 14 was asserted for one of six vault domains and neither agent domain | The spec names pause behaviour as a core invariant; five domains were unverified | All six vault domains asserted against a live queue, so a `NothingToClear` revert cannot masquerade as the pause; both agent domains asserted, including that pausing bridge-out does not block receipt of an in-flight transfer | `testEveryPauseDomainBlocksItsOwnOperation`, `testBridgeOutPauseBlocksSendsNotReceipts`, `testDeallocateNeverPaused` |
| F10 | `testReentrantAdapterCannotDoubleBook` used a bare `vm.expectRevert()` | Without the guard the recursion runs out of gas and reverts anyway, so the test passed with the reentrancy guard deleted | Selector pinned to `ReentrancyGuardReentrantCall` | the test itself |
| F11 | The invariant handler registered `closeAndClear` twice in a 15-slot array | Undocumented double weight on the most state-changing action, skewing every other action's sampling | Array reduced to 14, uniformly weighted; all six invariants still pass | the invariant run |
| F12 | No check tied `minTickInterval` to the confirmation depth | If `minTickInterval` ever fell below `confirmations x blockTime`, the hub reference block could precede the previous commit block and every commit would revert `InvalidHubReference` | Phase 4 and monitor check added. Current values pass with a wide margin (300 s against 20 s) | `checks/deployment.ts` |

---

## 5. Documented residuals, not defects

Accepted properties of the design, recorded so a reader does not mistake them
for oversights.

- **`writeDown` is advisory.** It writes `_sent[id].writtenDown`, which only the
  `getSent` view reads. It reaches NAV when the off-chain engine copies it into
  the snapshot's `InFlight.writtenDown`, and nothing on-chain binds the two. It
  is ADMIN with no timelock. It is still the correct recovery lever — a full
  write-down clears the overdue flag and unblocks entries, and a late receipt
  books the recovery against the same id — but the documents claimed an on-chain
  effect it does not have.
- **Remote position values are trusted** within the buckets. The hub-side fields
  (cash, pending deposits, liabilities, shares) are bound to the vault's own
  per-block checkpoints and cannot be misreported; remote values cannot be
  verified by any contract, because no contract can read another chain. The
  consistent cut, the agent set and the strategy identity behind a
  `KIND_STRATEGY_SHARES` position are all off-chain obligations.
- **Only the hub reference block is bound on-chain.** A spoke reorg changes
  position values with no on-chain detection; `verify-tick` catches it after the
  fact and the monitor raises critical.
- **Spoke agents cannot read the hub accountant**, so their breakers are
  guardian actions rather than automatic. The hub agent reads them automatically.
- **Clearing is permissionless, so the caller chooses which usable Tick clears an
  epoch.** Depositors want a low offer and redeemers want a high bid, so there is
  a race. It is bounded: a Tick that moved down more than
  `depositClearingMaxDown` cannot clear deposits at all, and redeems are capped by
  `min(openRateBid, ...)`. The operational requirement is that the keeper clears
  in the same pass as the Tick that enables it.
- **Funding is FIFO and all-or-nothing per epoch.** One large epoch blocks later
  small ones until capital is recalled, and recalls are bounded by the route
  volume bucket. Open item B6.
- **There is no per-epoch redemption cap.** Deposits are capped; redemptions are
  not.
- **Redeem rounding dust** (fixed, see D9). Clearing books the aggregate floor,
  claims pay per-request floors, and the difference stays in `reserved` and
  `liabilities` forever, so it keeps reducing NAV by a few wei per epoch.
  Conservative, negligible, and there is no sweep path.
- **Outflows are not measured.** `_pullExact` verifies inflows; claims and
  instant exits pay with an unverified `safeTransfer`. Correct for USDC, wrong
  for a fee-on-transfer asset, and `initialize` accepts any asset address.
- **Donations to the vault are invisible to NAV** and cannot be swept, because
  accounted cash moves only on measured transfers.
- **Reward tokens are not recognized** until swapped into the asset and held.
  Conservative.
- **The `EpochVaultLogic` library is deployed and its functions are `external`.**
  Anyone can call it directly, but a plain call executes against the library's own
  empty storage, and a delegatecall executes against the caller's storage, so
  neither can reach vault state. The security property holds; the reason is not
  the one the docs gave.

---

## 6. Decisions required

Genuine trade-offs, not bugs. Each is stated with the options and a
recommendation. Nothing here was changed unilaterally.

**D1. `ratifyTick` is an unbounded, instant, unilateral re-pricing.** ADMIN
promotes a Quarantined Tick to the latest accepted Tick. It consumes no bucket,
charges no fee, and sets the `rateBid`/`rateOffer` used by every clearing and
every instant exit. Combined with `grantRole(NAV_UPDATER)` it is a full
drain path. Options: (a) leave it, because a real large loss needs fast
resolution and a timelock would extend the settlement halt by the delay;
(b) split by direction — ADMIN may ratify a downward move, which is the
conservative direction, while an upward one requires the Timelock; (c) full
Timelock. Recommended: (b). It keeps fast loss recovery and removes the drain
primitive, and the direction test is one comparison against the last accepted
rate. **RESOLVED (b)** in the follow-up review: ADMIN ratifies a Tick at or below
the last accepted bid rate, the Timelock ratifies one above it. Cost: a donation
beyond the up bucket (T22) now halts settlement for the Timelock delay.

**D2. The Timelock is a transparency window, not a veto.** The same Safe holds
ADMIN on every contract and `Timelock.owner()`, and `queue`, `cancel` and
`execute` are all `onlyOwner` with no permissionless execution. The owner can
queue and execute in the same block, or cancel after the delay. The threat model
presents Governance and ADMIN as separate parties with different trust profiles;
they are one key. Options: separate the keys, allow anyone to execute after the
ETA, or both. Recommended: allow permissionless execution after the ETA, which
makes the delay real without needing a second key, and document that the Safe
still controls both halves.

**D3. Strategy-layer fees are ADMIN-instant while hub fees are timelocked.**
`Rebalancer.setPerformanceFee` reaches 25% and `setManagementFee` 5% with no
delay, on the contracts holding all cross-chain capital, while
`TickAccountant.setFees` is `onlyTimelock`. The asymmetry looks unintended.
Recommended: move the strategy fee setters behind the Timelock. Both are 0 as
deployed, so this is not urgent, but it is a hole under the layer where the same
decision was deliberately protected.

**D4. `Rebalancer.pause(Actions.Withdraw)` is ADMIN-instant and chains into a
full exit freeze.** It blocks `ChainAgent.deallocate`, which blocks recalls from
spokes, which blocks epoch funding, which blocks every queued redemption, with no
timelock and no threat-model row. Pausing must stay fast, so the fix is not a
delay; it is a dedicated critical monitor alert on the strategy's Withdraw domain
and an explicit runbook entry. Recommended: add both. **RESOLVED (alert)**:
`strategy.<chain>.paused` is critical on Withdraw, warning on Deposit.

**D5. `_setBuckets` has no upper bound on `up.capacity`.** One Timelock action,
with as little as the 30-minute `MIN_DELAY`, removes the rate corridor entirely.
The documents present the buckets as a hard bound on the NAV updater without
saying that governance can lift it. Recommended: an absolute ceiling constant
alongside `MAX_PERFORMANCE_FEE`, and a monitor warning when the bucket is widened
beyond the launch value. **RESOLVED**: `MAX_UP_CAPACITY` (2%) and
`MAX_UP_REFILL_PER_SECOND` (100%/year) in `TickAccountant`, mirrored and asserted
in `registry.ts`.

**D6. Provider concentration is not actually bounded.** Caps default to 0 =
uncapped, `AaveV3` ships uncapped on both chains because every deposit lands in
the entry provider first, and the non-zero caps sum to 160%. Decide the real
policy: either cap the entry provider too and route deposits through a two-step
allocation, or state plainly that provider concentration is an executor
responsibility bounded only by the caps that are set.

**D7. `maxChainExposure` ships disabled.** With two chains, all capital starts on
the hub, so any cap below 100% is breached on day one and the flag would be
permanent noise. Set it through the Timelock once a target allocation exists or a
third chain is added.

**D8. `minimumBuffer` is an absolute 10,000 USDC in production.** `pushToAgent`
requires available cash at or above the buffer, so the first 10k of TVL cannot be
deployed to yield at all, and at 100k TVL the absolute floor binds harder than
the 5% ratio. Deliberate conservatism or a launch drag — decide, and consider a
ratio-only buffer until TVL passes the floor.

**D9. Redeem dust (see §5).** Fixable by tracking claimed shares per epoch and
releasing the residual on the last claim, which needs one field appended to
`Epoch`. Cheap now, impossible after deployment without a storage migration.
Recommended: do it before the first mainnet deploy, or accept it explicitly.
**RESOLVED**: `Epoch.redeemSharesClaimed` and `Epoch.assetsPaid` are appended;
the last claim of an epoch releases the residual (`RedeemDustReleased`). Deposit
share dust (per-claim floors of `sharesMinted`) stays in escrow and is not swept.

**D10. Section 16's `messageId` and per-leg `rebalanceId`.** Recording the CCTP
nonce in `CctpV2Adapter.Sent` and adding a `rebalanceId` to `Allocated` and
`Deallocated` would make all eleven depicted states reconstructible on-chain.
Both are event-signature changes, so the indexer and any partner integration
must follow. Decide whether the audit value is worth the churn; today the honest
statement is that five states are derived from balances and views, not events.

**D11. No malicious-strategy test.** Invariant 7 is proven for the bridge leg
only. A mock `IERC4626` that returns less than expected on `redeem`, re-enters,
or reports an inflated `convertToAssets` would close it, and `deallocateShares`'
new floor is exactly the defence such a test would exercise.

---

## 7. Off-chain work

Carried from `crosschain-open-items.md`, plus what this audit added. None is a
contract defect. Three of them were closed in the same pass as the contract fixes;
the rest are genuinely open.

| # | Item | Status |
|---|---|---|
| O1 | No deployment manifests exist, so every ops service throws at startup. Nothing can run against a live network until phases 1-3 have been executed and `deployments/*/crosschain.json` committed | OPEN, and it is the gate for everything else |
| O2 | The transfer index was in-memory only, so every NAV service restart re-scanned all bridge events from `startBlock` on every chain, sequentially. The commit window is a fixed 256 blocks — about 490 s of usable budget on Base — so a cold start that outgrew it would make every commit revert `InvalidHubReference`, stopping ticks and with them all settlement and instant exits | FIXED. `TransferIndex` now persists to `TRANSFER_INDEX_FILE` atomically, reloads on startup, rewinds 5000 blocks as reorg insurance, and is bound to a fingerprint of the agent addresses so fork or stand state can never be loaded by production. `nav`, `monitor`, `relayer` and `verify-tick` all share it; the rehearsal points it into its throwaway directory |
| O3 | No archive-RPC canary. Every valuation read is pinned with `blockTag`; a pruned RPC that silently degrades it to latest produces a Tick with head-block values, and the accountant cannot catch it because remote values are trusted. On an idle vault the checkpoint comparison coincidentally agrees and the Tick is accepted | OPEN |
| O4 | The consistent cut could push a spoke reference block above its confirmation depth, because `index.sync` ran to the raw heads. Spoke block hashes are not bound on-chain, so a reorg there yields an accepted Tick with wrong values, contradicting `nav-reproduction.md` §2 | FIXED. `consistentCut` now takes per-chain ceilings; a send above its ceiling cannot be advanced to, so the receipt leaves the cut instead and the transfer stays in flight, valued at `minReceive`. Lowering a reference is always confirmation-safe, and the fixpoint still terminates. Pinned by `ops/test/snapshot.test.ts` |
| O5 | Quarantine produced an indefinite five-minute commit-and-alert loop: the NAV service never read `quarantined()`, and while a quarantine stands the "closed epoch waits for a post-cutoff Tick" condition stays true forever, so each pass committed another quarantined Tick, burned gas that settled nothing, and fired another alert | FIXED. The service now skips a commit when a quarantine already stands and the predicted move still exceeds the *refilled* bucket — computed with the same ceil arithmetic as `_consumeBuckets`, so it never suppresses a Tick the contract would accept, and an in-bounds Tick (which is what resolves the quarantine) always goes through. One alert per episode; the monitor owns the repeat cadence. `--force` overrides. Not covered by the rehearsal, which never quarantines: the arithmetic mirrors `_consumeBuckets` exactly (same direction choice, same ceil, same refill capped at capacity), so the skip can only fire on a Tick the contract would reject, but it is typechecked rather than executed. The trade-off is a gap in the on-chain append-only trail for skipped observations; the service log carries them |
| O6 | One agent per chain is assumed, never verified. Positions are read only from the manifest's `ChainAgent`, while `setAgent` permits N per chain and no contract can detect an omitted one. `nav-reproduction.md` states the invariant; nothing enforces it | FIXED in the monitor: `agents.<chain>` rebuilds the allowed set from `AgentUpdated` and is critical unless it is exactly the manifest agent |
| O7 | Two independent RPC providers per chain, which `nav-reproduction.md` §4 requires. Not implemented: one provider per chain, which is also the source of independence for the monitor's re-derivation | OPEN |
| O8 | Key management, hosting, and the allocation strategy | OPEN, items A1/A4/A5. Without A1 capital stays in the hub buffer and the hub strategy, which is safe but earns nothing |
| O9 | External audit | OPEN, item B1. Everything in §4, §6 and this table should be in scope, together with the snapshot spec and the ops NAV engine |

The monitor re-derived only the latest accepted Tick, so Ticks committed while
it was down were never verified. FIXED: it now walks every committed Tick over a
50-Tick backlog, five per pass (`MONITOR_VERIFY_BACKLOG`, `MONITOR_VERIFY_PER_PASS`),
and any mismatch stays critical.

---

## 8. What the system can now claim

The final objective of the brief is defensible, with two honest qualifications.

Thesauros maintains a transparent, independently reproducible view of capital
across chains: the snapshot is public calldata in a canonical ABI encoding, its
hash is committed on-chain, its arithmetic and all hub-side fields are verified
against the vault's own checkpoints rather than trusted, and any partner can
re-derive any Tick. Cross-chain operations are asynchronous state transitions
with measured amounts and single settlement per transfer id. Economic state is
committed in discrete, append-only Ticks. User operations clear in configurable
epochs at forward prices from a Tick observed after the cutoff. Nothing requires
synchronization between chains faster than the tick cadence. Under uncertain or
stale state, settlement is conservative by construction — bid for exits, offer
for entries, `min(open, clear)` for the queue, quarantine rather than revert for
a move outside the corridor — so the protocol cannot overpay against
unconfirmed value.

Qualification one: "independently reproducible" is a property of the published
method, not something the contracts enforce. Remote position values, the
consistent cut and the agent set are trusted from the NAV updater, bounded by the
rate buckets and checked after the fact by re-derivation.

Qualification two: the residual in `tick-accounting-design.md` §5.6 is
irreducible. A loss that occurs after the reference time and before clearing,
and is unobservable at the reference time, is borne by whoever is in the queue.
No accounting design removes it. It is bounded by the clearing lag, batch size,
the guardian pause and the fact that the two most common silent-loss sources
(Morpho share pricing and bridge slippage) are already handled by
`min(real, book)` and by burn-and-mint.
