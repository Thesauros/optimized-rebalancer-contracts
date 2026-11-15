---
title: Base cross-chain strategy upgrade opportunity research
date: 2026-11-12
status: active
project: optimized-rebalancer-contracts
author: product-agent
---

# Opportunity and PR/FAQ

The operator wants one reviewable Base release branch that brings the existing
cross-chain Strategy to current main and adds Fluid and Gauntlet Morpho V2.
Delivering one network first bounds the financial and operational change while
retaining the five existing provider positions.

Desired result: the existing Base Strategy can use the current security
accounting and seven provider venues, with evidence that existing holders,
positions and cross-chain operations are preserved. This task prepares and
verifies that release; it does not execute public-chain transactions.

| Question | Answer |
| --- | --- |
| Who benefits? | Cross-chain vault operators and existing depositors. |
| Why now? | Production still uses the legacy Strategy runtime; main contains the migration and two reusable integrations. |
| What is excluded? | Other networks, new allocation decisions, unrelated limits or roles, and ProviderManager/CCTP replacement unless separately authorized. |
| What establishes trust? | Pinned source identities, exact runtime/storage comparison, actual-state Base fork execution and independent QA/security review. |

# Result hypothesis

Metric: all three release capabilities are verifiable in one branch; zero
unintended changes to existing holder balances, funded positions, fees, entry
provider and authority. Leading indicators are a compiler-backed compatible
storage layout, successful atomic migration, seven distinct provider sources,
and successful small round trips through both new venues. Confirmation window:
this release preparation session and, after separately approved execution, its
first fresh NAV/allocation/exit observation. Reconsider the release if a source
cannot be verified, an existing position changes unexpectedly, or ops valuation
cannot reproduce the post-upgrade portfolio.

# Execution fit and template reuse

Improve the existing deterministic upgrade/governance workflow. Use agent-led
implementation and local verification with deterministic gates; retain human
judgment for historical HWM attestation and public execution.

| Criterion | Assessment |
| --- | --- |
| Outcome ambiguity | Three explicit capabilities; source addresses and migration values need evidence. |
| Process variability | Proxy initialization, provider deployment and delayed governance require separate stages. |
| Data/tool readiness | Existing manifests, main source, Base RPC and readiness/fork tooling are available; historical HWM is not stored by the old runtime. |
| Risk/reversibility | Local changes and forks are reversible; public-chain execution is a separate approval boundary. |
| Value/cost | Reusing current adapters and rehearsals reduces new code and review surface. |

Reviewed `.product-squad-skill/templates/sdd-opportunity-research.md` and
`templates/prd.md`; adapt their scope, metric and validation structure. Reuse
`specs/crosschain-strategy-upgrade-readiness-20261111/spec.md`,
`specs/ts-420-ethereum-fluid-provider/spec.md`, the readiness evidence, and the
Gauntlet deployment preparation workflow. Ethereum-only Fluid acceptance must
be extended with real Base source and fork evidence rather than assumed valid.

# Human validation and handoff

| Step | Reviewer | Criteria and evidence |
| --- | --- | --- |
| Scope/detailing | User and implementation owner | One Base branch; Strategy upgrade, Fluid, Gauntlet Morpho V2; this research and SDD. |
| Migration input | Governance owner | Explicit historical HWM value, provenance and fee-waiver acknowledgment; never replace it with a fork test value. |
| Pre-release | User, QA and Security | Exact deployment/governance bundle, candidate hashes, fork evidence and absence of unresolved critical/high findings. |
| Public execution | User/governance signer | Separate approval of the concrete transactions, funding and timings. |
| Post-release | Operator | Fresh valid NAV, expected sources/caps and successful allocation/exit checks. |

Handoff: implement `specs/base-crosschain-upgrade/spec.md`. Resolve Base source
identities through authoritative on-chain reads. Keep missing HWM or future
deployment addresses explicit in draft output, and do not claim execution
readiness while they are absent. Root orchestration owns durable role memory.
