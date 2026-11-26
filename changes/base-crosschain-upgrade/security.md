---
title: Base cross-chain upgrade preparation security review
date: 2026-11-12
status: active
project: optimized-rebalancer-contracts
author: security-agent
severity: informational
review-type: code
---

# Scope and verdict

Change: `base-crosschain-upgrade`. Review of the Base-only unsigned release
preparation, registry/deployment/monitor wiring and its authority boundaries
against `specs/base-crosschain-upgrade/spec.md`. This is not a new full audit of
the unchanged main Rebalancer, Fluid, Morpho V2 or external lending protocols.

Verdict: **PASS for the scoped unsigned preparation code; public execution
remains NO-GO until its release inputs are approved**. Final hardening source
and focused tests have been rechecked. No new exploitable critical/high
vulnerability has been validated in the reviewed preparation boundary. Public
execution is not approved by this review;
historical HWM attestation and the concrete deployment/release inputs remain
separate required evidence.

# Trust boundaries reviewed

| Boundary | Checked control / required evidence |
| --- | --- |
| Operator input to plan | Base chain/proxy fixed; malformed HWM/caps/addresses rejected; no guessed HWM or deployment address. Missing attestation flags, evidence references, caps or deployed/runtime-verified candidates suppress upgrade and governance calldata. |
| RPC observations to snapshot | Explicit chain-ID read, pinned block, manifest implementation/runtime checks, health/source/alias checks and canonical-block hash recheck. Preserved hub proxy implementations are attested separately. Exact legacy five-provider order, entry, caps and all five reviewed source addresses are enforced. |
| Local source to executable bytecode | Artifact ABI and both bytecodes match compiler output; all imported source content matches local files. Solidity 0.8.33, optimizer 200, EVM Paris and OpenZeppelin 5.4.0 enforced. Constructor simulation, fixed reviewed Rebalancer runtime hash, exact deployed candidate runtime matching and immutable-source checks bind the candidate. |
| Public RPC access | Closed allowlist in both `ReadOnlyRpc.send` and `_send`; no transaction submission, signing, account impersonation or storage mutation. New preparation code constructs no wallet/signer. |
| Upgrade authority | Actual ProxyAdmin owner is recorded; initialization is encoded inside the same `upgradeAndCall`, avoiding a bare upgraded-but-uninitialized interval. |
| Provider governance | Append complete preserved provider list; distinct sources; actual Timelock queue/execute/cancel tuples. Registration and two cap changes are staged; executor quiescence or an actual Safe atomic batch is required until all succeed. |
| Scope | Only existing Base cross-chain Strategy; original funded venues/entry remain. No PM migration, bridge replacement, additional network activation or role/fee change. |
| Local output/process execution | Static bundle filenames, exclusive file creation and no overwrite; constant-argument `execFileSync` calls without a shell. RPC URLs are scrubbed from errors; output contains public observations and hashes, not signer material. |

# Evidence reviewed

- Independent final preparation/deployment suite: `npm run test:deploy`,
  **34 passed, zero failed/skipped**, after final hardening. The suite rejects
  public send/sign/mutation at both RPC boundaries, execution CLI flags,
  missing migration evidence, immutable-runtime mismatch and bundle overwrites.
- Independent focused ops registry/monitor suite: 11 passed, zero failed/skipped;
  wrong Fluid source rejected and missing provider manifests reported explicitly.
- Ops typecheck and final separate preparation-script typecheck passed.
  Real Rebalancer/FluidProvider/MorphoV2Provider artifacts each independently
  pass the compiler-output coherence assertion and EVM Paris check.
- Compiler-backed legacy storage and atomic migration evidence in
  `changes/crosschain-strategy-upgrade-readiness-20261111/`; the current main
  Rebalancer project import graph matches that evidence's target.
- Corrected actual-state Base expansion fork reported six passed, no skips at
  block 55,863,000: atomic migration/preservation, Fluid/V2 round trips, cap
  rejection, Fluid exchange-price/APR agreement, and actual ChainAgent
  allocation/deallocation/returnFunds. The additional hub payout test passes
  using actual Base contracts and an explicitly modeled remote NAV/block refs;
  stale payout rejection is observed before a normal authorized fresh commit.
  This does not attest the production remote NAV or service release.
- Inspected final live read-only draft v3 at Base block 56,476,408, hash
  `0xfa18b26877f45a393baf9e8d05de946a7a5aa46c26d1038a055d9d2f333dbcc2`:
  DRAFT_NOT_SIGNABLE, five old providers, all five sources matching the prior
  deployment attestation, three constructor plans, null atomic upgrade and no
  governance calls. Target runtime is the reviewed `0x6a9f9388…9026b`.
  Recorded final preparation-script hash matches the reviewed script. Compact
  evidence is persisted as `preparation.json`; actual deployed candidate
  addresses remain null and runtimeVerified remains false, as required for a
  constructor-only draft.

# Release conditions and limits

1. Historical HWM is a governance attestation with provenance, not the current
   PPS selected by a fork test. Recheck the ceiling PPS at execution and obtain
   explicit legacy-fee-waiver acceptance.
2. Candidate implementation/provider addresses must actually exist and match
   the reviewed bytecode/immutable sources. Constructor transaction data alone
   does not establish a deployed release.
3. Confirm the running ops release, fresh accepted NAV, correct seven-provider
   configuration and sufficient execution funding before public execution.
4. Preserve exact Timelock tuples and staged ordering. Do not allocate into a
   newly registered uncapped venue before its reviewed cap is installed.
5. Existing stand governance/key concentration, external protocol governance,
   provider-failure settlement policy and nonproxy PM/CCTP migrations are not
   resolved or globally cleared by this scoped change.

These are execution prerequisites and existing trust boundaries, not fabricated
exploit reports. Final review must distinguish acceptance of a prepared branch
from approval to send public-chain transactions.
