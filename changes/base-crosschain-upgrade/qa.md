---
title: Base cross-chain upgrade QA verification
date: 2026-11-12
status: active
project: optimized-rebalancer-contracts
author: qa-agent
---

# Verification scope

Spec: `specs/base-crosschain-upgrade/spec.md`, AC1–AC9. This review verifies
release preparation on Base; it does not approve public-chain execution.
Reviewed the preparation CLI, registry/deployment wiring, deployment monitor,
tests and operator runbook independently of their implementation authors.

Gate: **PASS for the implemented and prepared Base release branch**.
All scoped acceptance criteria have evidence. This verdict does not approve
public execution or attest the running remote ops release/global NAV service.

| Acceptance | Current verdict | Evidence |
| --- | --- | --- |
| AC1 identity/source drift | verified | Final v3 preparation at block 56,476,408 pins actual implementation/runtime, preserved hub proxies, old five sources/order/entry/caps and compiler output. Its recorded script hash matches the reviewed script. Wrong-chain/runtime/source/cap negatives pass. |
| AC2 atomic migration/preservation | verified | Six-test actual-state fork evidence at Base 55,863,000; all ten prefix words covered with intentional accounting resets separate; actual holdings, supply and old positions/caps preserved. |
| AC3 bad initialization | verified | New planner rejects missing/zero/too-low inputs. Current SecurityRemediation unit coverage within the 199 passing tests rejects public caller, low HWM and repeat initialization; existing Base readiness fork evidence for the identical target runtime additionally proves bare-upgrade valuation blocked. |
| AC4 seven providers and delayed registration | verified | Full legacy list/order retained, two distinct sources appended; registration and both caps executed through actual 24-hour Timelock, with early execution rejected. |
| AC5 Base Fluid/V2 round trips | verified | Persisted expansion fork evidence proves real Base source round trips, cap rejection and Fluid APR/exchange-price consistency; zero skips. |
| AC6 financial integration/payout | verified within explicit model boundary | Actual ChainAgent allocation/deallocation/returnFunds; separate passing hub test funds both new venues, proves stale-Tick rejection, then normal authorized Tick commit, recall/return/push/allocate and real-holder payout. Remote NAV/block references are modeled. |
| AC7 ops integration | verified for branch; remote runtime unverified | Eleven focused registry/monitor tests and nine valuation/failure tests pass independently. New seven-source fixture isolates Fluid/V2 failure or retarget without allowing incomplete NAV settlement. Final full ops suite: 102 passed, zero failed/skipped; ops typecheck passes. |
| AC8 incomplete inputs stay non-signable | verified | Missing attestation/evidence/caps/addresses yield DRAFT_NOT_SIGNABLE, null upgrade/provider list and no governance calldata. |
| AC9 public-write isolation/review evidence | verified | Both RPC boundaries reject send/sign/mutation; CLI rejects execution flags; no signer construction. Local Foundry processes exit; evidence records no public writes. QA/security reports and staged runbook exist. |

# Independently executed checks

- `npm run test:deploy`: **34 passed, 0 failed, 0 skipped** after final hardening. Includes all eleven
  new preparation tests, existing deployment dry-run protections, immutable
  runtime checks, bundle overwrite/path-traversal protection and RPC isolation.
- `cd ops && node --require ts-node/register/transpile-only --test test/registry.test.ts test/deployment-networks.test.ts`:
  **11 passed, 0 failed, 0 skipped**. Includes missing-provider manifest handling,
  wrong Fluid source rejection, exact seven-provider order and unchanged other
  network expansion configuration.
- `cd ops && npm run typecheck`: **passed**.
- `cd ops && node --require ts-node/register/transpile-only --test test/strategy-value.test.ts`:
  **9 passed, 0 failed, 0 skipped**, independently rerun after the seven-source
  case was added. This fixture tests valuation arithmetic/failure handling;
  it does not reconstruct live global NAV.
- `./node_modules/.bin/tsc --noEmit --module commonjs --target ES2022 --esModuleInterop --skipLibCheck scripts/prepare-base-crosschain-upgrade.ts`:
  **passed**, including rerun after final hardening.

Final author/root execution evidence, independently read and matched to source:

- `base-expansion-fork-verification.json`: **6 passed, 0 failed, 0 skipped** at
  Base block 55,863,000; corrected storage assertions and real-source paths.
- `hub-payout-verification.json`: **1 passed, 0 failed, 0 skipped**, same Base
  pin; actual existing holder receives tokens and burns 500,000 shares.
- Final full ops suite: **102 passed, 0 failed, 0 skipped**; non-fork Solidity
  regression/invariants: **199 passed, 0 failed, 0 skipped**.
- `preparation.json`: current final CLI creates DRAFT_NOT_SIGNABLE with null
  atomic upgrade, empty governance and no guessed actual deployment addresses.

# Findings and operational conditions

1. **QA-BASE-001 — medium, corrected and reverified, test defect.**
   `test/forking/BaseStrategyExpansion.t.sol` initially captures eight legacy
   storage words and asserts slot 7 unchanged. Compiler-backed legacy layout
   identifies slot 7 as `_lastTimestamp`, deliberately reset by initialization;
   ten legacy words precede HWM. The test also omits raw preservation of fee slot
   5 and min-assets slot 8. Reported to the author before final fork verification.
   Corrected source captures slots 0..9, asserts 0..5 plus 8/9 unchanged and
   checks intentional baseline resets 6/7 separately. Fork author reports the
   corrected preservation test and all six expansion tests pass at Base block
   55,863,000, with zero failures/skips. Product contract behavior is not
   implicated by this test error. The final result is persisted in
   `base-expansion-fork-verification.json`.
2. Registration and both cap changes are separate Timelock executions. The
   runbook explicitly requires an executor freeze until all three succeed, or
   an actual Safe atomic batch. A JSON array is not an atomic execution claim.
3. Registry caps 30%/20% are labeled proposed ceilings; the CLI still requires
   explicit cap inputs. They are not allocation targets or existing approval.
4. Historical HWM evidence, legacy fee-waiver acceptance, actual candidate
   addresses, fresh NAV, remote ops revision and execution funding remain
   release inputs. A successful local fork cannot attest them.

The payout test deliberately derives a controlled remote value to preserve the
previous PPS and supplies simulated local/remote block references. Base values
come from actual seven-provider holdings, and real accountant freshness/risk
checks remain active. It proves Base financial plumbing, not independent
production cross-chain NAV re-derivation or current remote service health.

No unresolved critical/high implementation defect remains in this scoped branch.
Missing production migration/operational inputs do not prevent acceptance of
the requested prepared code branch and must not be interpreted as release approval.
