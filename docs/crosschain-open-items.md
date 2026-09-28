# Cross-chain vault: what is still needed

State on 2026-09-28, branch `feat/crosschain-tick-epoch`.

**Done:** contracts, deployment phases 1–5 for Base and Arbitrum, and the four
services (NAV updater, keeper, CCTP relayer, monitor), rehearsed end to end on
forks. Sections A–C below are **not** done; each item is marked with whether it
blocks the first mainnet deployment. Section D records what was closed on
2026-09-28, so that the earlier sections are not read as the current state.

## A. Backend that is not built

| # | Item | Blocks launch? | Why it is needed | Suggested home |
|---|---|---|---|---|
| A1 | **Cross-chain allocation strategy** (spec for the backend developer: `docs/tz-crosschain-allocator.md`) (the "brain"): decides how much sits on Base vs Arbitrum and in which provider, executes allocate / rebalance / bridgeOut, and plans recalls from spokes to fund redemptions | **Yes, for yield.** No, for safety: without it capital stays in the hub vault buffer and hub strategy | The existing `Thesauros-Rebalance-Engine/apps/rebalancer` drives single-chain `Rebalancer.rebalance`; it does not know `ChainAgent`, CCTP or cross-chain liquidity. The keeper's autofund covers hub-local recalls only | Extend Rebalance-Engine (it already has provider-rate data, Safe SDK and AWS Secrets Manager) with a `crosschain` module calling `ChainAgent` / `EpochVault.pushToAgent` |
| A2 | ~~Indexer + API for the frontend~~ **Done**: `ops/src/indexer.ts` (rehearsed on forks) | — | — | — |
| A3 | ~~Frontend flows~~ **Done**: `thesauros-app` branch `feat/crosschain-vault`, page `/crosschain` (builds; not yet exercised against a live deployment) | — | — | — |
| A4 | **Key management for hot keys** (NAV updater, executor, keeper/relayer) | Yes | Hot keys in `.env` repeat SEC-002 | AWS Secrets Manager / KMS, as the Rebalance-Engine already uses |
| A5 | **Hosting** for the four `ops` services and paid RPCs (a different provider for the monitor than for the NAV updater) | Yes | Liveness: no Ticks means no clearing and no instant exits | Railway, like the existing services |
| A6 | Public snapshot archive (optional): JSON of every Tick for partners | No | The snapshot is already public as calldata; `ops/src/verify-tick.ts` reproduces any Tick | docs site / data service |

## B. Protocol gaps (known and documented)

| # | Item | Blocks launch? | Note |
|---|---|---|---|
| B1 | **External audit** of `TickAccountant`, `EpochVault` + `EpochVaultLogic`, `ChainAgent`, `CctpV2Adapter`, the `Rebalancer` diff, the snapshot spec, and the ops NAV engine | **Yes, before meaningful TVL** | Internal tests: 157 Foundry (105 new on this branch + 52 pre-existing; 156 pass and the one exception is the assertion-free `NewVaultWithdraw` harness that needs a `VAULT` env var) and 18 `ops` cases from 13 declarations, invariants, negative controls, fork rehearsal. The spec-by-spec audit with its findings and the decisions still open is `docs/tick-epoch-spec-audit.md`. Counts and the exact commands: `docs/implementation-report.md` §18 |
| B2 | Reward tokens (COMP, Morpho rewards) are neither claimed nor recognized | No | Conservative: they are simply not counted |
| B3 | Deposits on spokes | No | V1 is hub-only; users reach Base via CCTP themselves |
| B4 | Plasma (USDT0) and Monad | No | USDT0 needs an FX rule; CCTP availability on Monad is not verified |
| B5 | `Rebalancer` fee high-water mark | No | Strategy fees are 0; vault fees go through the accountant, which has a HWM |
| B6 | Partial funding of a large epoch | No | A large epoch blocks later small ones until funded; there is room in `EpochVault` for it now. It is the unbounded leg of withdrawal latency (`docs/epoch-benchmark.md` §7) |
| B7 | CCTP fast transfers | No | Supported by configuration (`minFinalityThreshold` 1000 plus `maxFeeBps`); defaults to standard |
| B8 | **Slither CI waiver.** `.github/workflows/security.yml` runs with `fail-on: high` and does not set `filter-paths`, so three High-impact results in `node_modules/@openzeppelin` (`incorrect-exp` in `Math.mulDiv`, `incorrect-return` in `TransparentUpgradeableProxy._fallback`, `msg-value-in-nonpayable` in `ERC1967Utils`) fail the workflow on every branch | No, for safety — yes, for a green branch | The eight results this branch added on its own code are resolved in source: each measured-amount site carries an inline `slither-disable-next-line` (or a `disable-start`/`disable-end` pair) with its justification, so `slither contracts --exclude-low --exclude-medium --exclude-informational --exclude-optimization` now reports **3 results, none in `contracts/`**. What is left needs a workflow change, not a code change: add `filter-paths: node_modules` (or a Slither triage file). Deliberately not done here, since editing CI is a separate decision. Detail in `docs/implementation-report.md` §18 |
| B9 | **`maxChainExposure` is deployed at 0 (disabled)** | No | The mechanism is implemented and tested; it is off because with two chains all capital starts on the hub and any cap below 100% is breached on day one. Turning it on needs a target allocation first (A1) or a third chain, then `setMaxChainExposure` through the Timelock. See §D and `docs/crosschain-limits.md` §3 |

## C. Decisions and actions for the founder

| # | Item |
|---|---|
| C1 | ~~Timelock delay~~ **Decided: 24 h** |
| C2 | Distinct NAV updater, executor and guardian keys: **after the stand test** (stand uses `0xafA9…8F9D` for everything; rotation with `06-rotate-governance.ts`) |
| C3 | Launch limits: stand and production values in `docs/crosschain-limits.md`. Three of them are no longer free choices — `maxSnapshotAge`, `maxClearingDelay` and `instantFee` are **derived** in `registry.ts` from the `blockhash` window, `maxTickAge` and the down-bucket capacity, asserted at module load, and re-checked on-chain in phase 4 and by the monitor (relations and reasoning: `docs/epoch-benchmark.md` §5.1). A retune of any input has to keep the relations, and the deploy fails if it does not. What is still a placeholder rather than a measurement: `maxTransit` (1 h) and `maxOverdueInFlight` (0), both waiting on real CCTP latency |
| C4 | Safe signer availability: **stand uses the deployer EOA**; revisit the Safe threshold before rotation |
| C5 | **Legacy `CrossChainVault` (SEC-018): open, and the key question changed.** The founder reports not having deployed it. On-chain (Blockscout, checked 2026-09-28) the contract `0x8AD87BB0…78a8Ae` was created by `0xafA9ed53…8F9D` (tx `0x7419a4a4…3c0c`), which also granted its roles and ran its operations on 2026-05-04..06. So whoever deployed it used the Thesauros deployer key. That key is in plaintext in `.env` files (SEC-002), and the stand profile gives it every role. Before the stand holds any money: establish who used the key in May 2026, or rotate to a fresh key for the stand |

## D. Closed on 2026-09-28

Recorded so the list above is not read as the current state of these items. Each
is implemented and tested on this branch; none of them is a launch blocker any
more, and B9 is the one that stays open by choice.

| Item | What changed | Tests |
|---|---|---|
| Per-chain concentration cap | `FLAG_CHAIN_EXPOSURE`, `setMaxChainExposure(uint128)` (`onlyTimelock`, `InvalidConfig` above 1e18, 0 disables), views `maxChainExposure()` / `isChainOverExposed(chainId)` / `chainSendAllowed(dst)`, exposure derived in `NavSnapshot.chainBids`, and `ChainAgent.bridgeOut` now calls `chainSendAllowed(route.dstChainId)` on the hub. Deliberately not a `Config` field, so no `setConfig` caller changed. Blocks sends **into** an over-cap chain only; never sends out, never settlement, and the flag is not in `DEPOSIT_BLOCKING_FLAGS`. **Ships disabled** (B9) | `testChainExposureDisabledByDefault`, `testChainExposureCapRejectsAboveWad`, `testOverExposedHubCanStillSendOut`, `testOverExposedSpokeRefusesInboundSends` |
| A deposit locked in a closed epoch had no exit | `cancel` now also accepts a Deposit whose epoch has `depositsCleared == false`, after the cutoff. Refunding pending deposits is NAV-neutral, so it cannot be used to leave at a pre-loss price; a Redeem stays non-cancellable past the cutoff, because its price is fixed only at clearing and a late cancel would be a free option on the epoch's yield | `testCancelRulesAroundCutoff`, `testCancelAfterCutoffWhileFrozen` (replacing `testCancelOnlyBeforeCutoff`); the invariant handler's `cancelLatest` fuzzes the new path |
| A Tick rejected on spread spent rate-bucket capacity | `commitTick` tests the `maxSpread` bound before `_consumeBuckets`, so a quarantined Tick no longer drains the bucket | `testSpreadRejectionSpendsNoBucket` |
| A position on a chain dropped from the set could be carried | `_validateMembership` reverts `UnknownChain` for any position whose chain is not configured, not only for an unregistered agent. Such a position was counted by `totals()` but invisible to `chainBids()` | **None dedicated.** The adjacent paths are covered by `testUnknownAgentPositionRejected` (`UnknownAgent`) and `testChainSetMustMatch` (`ChainSetMismatch`) |
| `deallocateShares` had no slippage floor | New `deallocateShares(uint256 shares, uint256 minAssets)` with `SlippageExceeded`; the received amount is still measured. Closes the asymmetry with `deallocate`, which already enforced exactness | `testDeallocateSharesEnforcesFloor` |
| Registry values could drift out of coherence | `maxSnapshotAge` (8 min, below the 256 × 2 s ceiling; was 10 min and unreachable), `maxClearingDelay` (`maxTickAge + maxSnapshotAge + 15 min`; was 1 h against a 2 h `maxTickAge`) and `instantFee` (0.25%, ≥ the 0.2% down bucket; was 0.1%) are now derived, with module-level assertions. Four coherence checks run in phase 4 and continuously in the monitor, plus a reporting line for `maxChainExposure` | `testInstantFeeMustCoverTheDownBucket` shows both the vulnerable and the fixed configuration |
| Pause coverage was asserted, not demonstrated | `testEveryPauseDomainBlocksItsOwnOperation` exercises all six vault domains against a live queue; `testBridgeOutPauseBlocksSendsNotReceipts` shows the agent's `BridgeOut` domain stops sends but not receipts; `testReentrantAdapterCannotDoubleBook` now pins `ReentrancyGuardReentrantCall.selector` instead of a bare `vm.expectRevert()` | as named |
| `ops` ABIs lagged the contracts | `chainSendAllowed`, `maxChainExposure`, `isChainOverExposed` and `deallocateShares` added to `ops/src/abi.ts` | `ops/test/abi.test.ts` |
| Invariant handler weighting | A duplicated `closeAndClear` selector removed from the weighted array (15 → 14), which had been giving the epoch lifecycle double sampling | `CrossChainInvariants.t.sol` |
