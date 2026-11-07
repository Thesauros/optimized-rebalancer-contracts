---
title: Solana Kamino delivery verification
date: 2026-11-07
status: active
project: optimized-rebalancer-contracts
author: qa-agent
---

# Change: solana-kamino-crosschain

Branch `feat/solana-kamino-crosschain`, based on fetched `origin/main`
`106e9059f8fd5e433a2ddd62555a1ede427020a7`. Local delivery only; no push,
production deployment, governance execution or real-fund transaction.

## Requirement traceability

| Requirement | Evidence | Result |
|---|---|---|
| R1 branch / local commit | Git ancestry matches fetched main; final local commit records this change | Verified; publication excluded |
| R2 native family boundary | Native registry, genesis validation, alias vector matching Solidity, EVM registry tests | Verified |
| R3 deposit / redemption / custody | Real agent SBF + real SPL token CPI in local validator; SDK instruction/account vectors; pinned USDC accounts and measured deltas | Verified in local VM; Kamino protocol is an explicit CPI double |
| R4 authorization / pause | Initial paused state, wrong executor rejection, minimum-output rollback, unwind during pause, fixed account checks | Verified |
| R5 CCTP full-width authentication | New Base adapter tests; actual Circle mainnet bytecode in local VM; native PDA burn; valid secp256k1 attestation; sender forgery and replay rejected; receipt during pause | Verified |
| R6 limits / durable transfer state | Existing ChainAgent route fee/amount tests; native bucket/rounding tests; bounded governance write-down and historical cut; signed-byte retry journal test | Verified |
| R7 real position and yield | Reserve SF/cToken exchange-rate and rounding vectors; SDK utilization-driven APR/APY test; live read-only USDC reserve / market / APR/APY | Verified |
| R8 NAV / history / consistent cut | Existing snapshot hash vector remains unchanged; mixed-family cut tests; finalized PDA reader, transfer source indexing, slot hash and SQLite restart recovery in VM | Verified |
| R9 operations / readiness | Dry-run commands, native preparation and lookup table builders, Base unsigned Timelock calldata, relayer branches, preflight, journal/cache and runbook; v0/LUT receive exercised in VM | Implemented and locally checked; actual deployment and continuous services not launched |
| R10 future strategies | Shared native custody/transport/checkpoints/index/journal; explicit strategy adapter API and append-only registry; historical subset compatibility | Code reviewed and tested for Kamino adapter; a future protocol needs its own adapter tests |
| R11 EVM compatibility | Full non-fork Foundry regression, deployment tests, ops tests, unchanged core Solidity/storage and canonical v1 snapshot | Verified |

## Executed checks

- Hardhat compile succeeds with `FOUNDRY_AUTO_DETECT_REMAPPINGS=false`.
- `forge test --no-match-path 'test/forking/*' -q` succeeds: 188 discovered
  tests/invariants across 12 suites, including the new native adapter suite.
- Existing deployment/preparation regression: 23 tests pass.
- Ops TypeScript typecheck succeeds; ops regression: 65 tests pass.
- Native Rust host tests: 7 pass, including full-width arithmetic, origin/caller/
  hook authentication, route limits, integer fee rounding and exact checkpoint
  serialization sizing.
- Actual SBF v2 build succeeds with cargo-build-sbf 4.5.0 / platform-tools 1.57.
  An earlier SBF v3 build also succeeds; installed validator compatibility tests
  use v2. The build emits an upstream Anchor `AccountInfo::realloc` deprecation
  warning; there are no build errors.
- Real local VM: initialization, observation, deposit, complete redemption,
  principal conservation, executor rejection, atomic minimum-output rollback,
  pause/unwind and fixed recipient checks pass.
- Additional real-Circle VM test passes: native PDA burn, actual secp256k1
  attestation verification, authenticated receive while paused, forged sender
  rejection, replay rejection, bounded governance write-down, finalized source
  transaction indexing, historical position values, native block hashes and
  SQLite restart recovery.
- `git diff --check` passes.
- Ops `npm audit` reports zero vulnerabilities after targeted overrides and the
  pure-JS bigint conversion replacement. Dependency install uses the lockfile
  with lifecycle scripts disabled.

The combined Circle/runtime VM evidence is in the local validator run ending
`thesauros-solana-sbf-zv8Epm`; the reproducible test is
`ops/test/solana-sbf.e2e.ts`. It uses synthetic USDC, test governance and a test
attester inside the local validator. Its Kamino component is explicitly named
`thesauros-test-kamino`, not presented as deployed Kamino bytecode.

## Live read-only evidence

Mainnet genesis RPC returned
`5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d`; this is distinct from the
short CAIP-2 reference. At slot 466639011, the selected reserve was owned by
`KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD`, version 1, in market
`7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF`, with native USDC mint
`EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` and six decimals.

`npm run solana -- rates` read slot 466641155 and returned supply APR
0.03830929814593532, APY 0.03905255879324887 and freely available liquidity
21,000,514,806,621 micro-USDC. These are dated observations, not configuration
constants or promised yields. The market referral fee and reserve reward cap
were read as zero at that observation, not assumed in code.

Official public Circle program bytecode was downloaded read-only for local VM
execution. SHA-256:

| Program | Digest |
|---|---|
| TokenMessengerMinter V2 | `ccdac46adb68c570556bd15f7caddc52dd16fb96e0bbc8f5a46129555adbeeb2` |
| MessageTransmitter V2 | `abbe67181ec4edcad11f4a0773d8bf658b2e599d6f1365ebfee1ab0f85fe9bb4` |

Interface sources inspected: Kamino klend-sdk commit
`6a26d6f1b5afb29953ffd139ee8c0c4ca5f26ce6` (package pinned 13.0.3), Circle
solana-cctp-contracts `ec16e95d28ee47f7832df4203ae07b5981d146fc`.

## Security review

This is a sequential role-based review in one session, not an external audit.
Trust boundaries reviewed: Base hub permissions; full-width native route
mapping; CCTP origin/caller/recipient/mint/hook; native PDA signing; fixed
protocol/account binding; finalized historical valuations; restart/cache/journal;
operator role/key separation; dependency/native-addon exposure.

Resolved review findings:

1. Native CCTP receive plus atomic valuation exceeds the legacy packet limit.
   Use v0 transactions, activated lookup tables, an explicit packet-size guard,
   unsigned lookup-table preparation and a preflight requirement. Verified using
   actual Circle bytecode in the VM.
2. The short CAIP-2 reference is not the full mainnet genesis hash. Pin the full
   RPC-verified hash; explicit local genesis also binds caches and journals.
3. Native account history replay grows over time. Persist validated checkpoints
   in a deployment/genesis-bound SQLite WAL cache and test restart recovery.
4. Checkpoint rent should scale with actual positions and NAV demand. Allocate
   exact serialized size and refresh on hub NAV/settlement demand; retain
   immutable observations for independent historical verification.
5. SDK transitive dependencies included vulnerable native bigint conversion
   and parser/WebSocket versions. Replace bigint conversion with bounded pure
   JS, pin patched compatible dependencies and disable install scripts. Unit
   conversions, live RPC reads, local RPC/VM integration and audit pass.
6. Native pending transfers initially bypassed the common age alert. Both
   native and EVM relaying now use the same pending-transfer alert path.

7. A retried journaled transaction must reconcile its original signature before
   simulating against state it may already have changed. Reordered recovery;
   restart test rejects any new simulation after the original becomes finalized.
8. Production native bytecode and read/send cluster must be explicit. Verify
   the reviewed ProgramData SHA-256 and full genesis on both RPCs; preflight
   requires an off-curve governance PDA and matching upgrade authority when
   upgradeable. Runtime tests reject mismatches. An off-curve address alone is
   not proof of a timelock; the governance program still requires human review.

RustSec scan with cargo-audit 0.22.2 against database commit
`309392b18f6b17022f82c701f300433126901068` (2026-11-06) examines 274 locked
dependencies: zero vulnerability findings. Registry yank checking was excluded
(`--no-fetch --no-yanked`); the database was freshly fetched using system Git.
Three informational warnings remain:

- `bincode` 1.3.3 (RUSTSEC-2025-0141) and `libsecp256k1` 0.6.0
  (RUSTSEC-2025-0161) are unmaintained upstream Solana dependencies. Severity
  low for this change; do not change Solana wire/crypto dependencies ad hoc.
- `rand` 0.7.3 (RUSTSEC-2026-0097) has custom-logger/thread-RNG unsoundness.
  Not reachable in this dependency feature graph: `cargo tree -e features
  -i rand@0.7.3` shows the required `log` feature is absent; agent code has no
  RNG/custom logger. The version's `std` feature does expose `thread_rng`;
  the missing logger condition is the relevant exclusion. Track upstream Solana dependency
  migration; this is not reported as a fixed upstream advisory.

No open critical/high finding was identified within this review's tested scope.
This is an implementation review result, not production activation approval.

## Activation limits

No live deployment manifest or deployment keypair is invented. Deployment still
requires the intended program identity, reviewed timelocked governance/upgrade
authority, native role keys, funded SOL gas/rent accounts, active lookup table,
manifest, Base adapter deployment and queued/verified Timelock configuration.
Native governance unpauses only after both endpoints and accounting are ready.

A capped live round trip using the deployed Kamino program and Circle Iris has
not been performed. Before production activation, run that authorized rehearsal,
including full unwind, observer/relayer/monitor operation, RPC/history capacity,
supported SBPF architecture and explicit rent budget. This work delivers the
implementation and verification package; it does not activate production.
