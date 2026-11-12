# Base cross-chain Strategy release branch

Change: `base-crosschain-upgrade`. Base: main `32f7dcf`.
Branch: `feat/base-crosschain-upgrade`.

QA and Security: PASS for the prepared Base branch. Public execution requires
the separate release inputs below and has not been performed.

Implemented the three requested Base capabilities in one branch: preparation of
the existing Strategy's current Rebalancer upgrade, Fluid fUSDC, and Gauntlet
USDC Prime Morpho V2. The original five providers remain in their existing order
and the Aave entry is retained. New proposed ceilings are Fluid 3000 bps and
V2 2000 bps; the unsigned planner requires explicit matching reviewed inputs.
No capital allocation is implied by these ceilings or provider registration.

The contracts already in main implement the target behavior. This branch adds
Base sources, fresh deployment integration, a scoped unsigned upgrade/governance
planner, source-aware monitor checks, regression/fork coverage and an operator
runbook. EpochVault, TickAccountant, ChainAgent, ProviderManager, CCTP endpoints
and live deployment manifests are not replaced by this scoped change. No other
network is added or activated.

## Evidence

| Check | Result |
| --- | --- |
| Hardhat compile | 88 Solidity files, Paris, Solidity 0.8.33, optimizer 200 |
| Solidity non-fork regression and invariants | 199 passed, zero failed/skipped |
| Actual-state Base expansion fork | 6 passed, zero failed/skipped at block 55,863,000 |
| Additional actual Base hub payout path | 1 passed, zero failed/skipped, with modeled remote NAV |
| Full ops suite including seven-provider valuation | 102 passed, zero failed/skipped |
| Seven-provider valuation / fee and failure suite | 9 passed, zero failed/skipped |
| Deployment/preparation suite | 34 passed, zero failed/skipped after final guards |
| Ops and preparation-script typechecks | passed |
| Live constructor-only preparation | DRAFT_NOT_SIGNABLE; current source identities and candidate constructor simulations verified |

Reproduction commands and staged release instructions are in
`docs/base-crosschain-upgrade.md`. Evidence:
`base-expansion-fork-verification.json`, `hub-payout-verification.json`,
`preparation.json`, `qa.md` and `security.md` in this directory.

The hub payout test intentionally models the unchanged remote leg and local
block references. It does not attest full cross-chain NAV re-derivation or the
running server image. Real Base contracts enforce the stale-Tick gate before
an authorized fresh snapshot is committed, and both new venues are funded.
No freshness/risk limit is bypassed to obtain a successful payout.

The live bundle has no guessed addresses or fabricated historical HWM. Missing
actual deployments, governance HWM/source evidence, fee-waiver acceptance and
reviewed caps suppress all upgrade/governance calldata. Complete unsigned
preparation still requires fork/human review and separately approved execution.

## Release inputs remaining

Historical HWM and source attestations with provenance, acceptance of legacy
fee treatment, reviewed caps, actual verified candidate deployments, fresh NAV,
compatible remote ops release, gas funding and exact reviewed execution tuples.
The branch and its passing tests do not authorize deployment, service restart,
governance execution or production allocation.
