---
title: Optimized security remediation validation and migration boundary
date: 2026-10-27
status: local-validation-passed-independent-review-pending
project: optimized-rebalancer-contracts
author: cto-agent
---

# Verified local behavior

The common implementation addresses SC-001/003/004/005/007/008/010. Main baseline
is e603e9a3d05369ff8f139179c516bfc1d9e8452f; dev baseline is
47e1c71920f6e011a8131fa5cf6c3314ab9b435b. Each has a separate local security branch.
No original checkout changes, production environment/keys, RPC, deployment or push.

Native solc0.8.33 and Foundry1.8.6 executed real local EVM tests, not mathematical
substitutes: main169/169, dev42/42; fifteen dedicated security tests in each branch.
Main's six grouped crosschain invariants passed64runs,8192calls (depth128).
Existing main deployment/preparation Node tests passed23/23 under an isolated
Hardhat config with no fork/network/environment loading. All-network factory
wiring checks passed for both source branches. CTO skill validation passed;
git diff --check is clean.

Compiler-backed storage probes preserve the ERC7201 namespace and every original
struct member's slot/offset/type: main12fields, dev11fields. Appended HWM/source
mapping occupy main slots10/11 and dev slots9/10. The local legacy-layout EVM
upgrade fixture preserves token metadata, balances, allowance, total supply,
admin/executor roles, fee settings, providers, treasury and timelock, then permits
a normal withdrawal after atomic ProxyAdmin upgradeAndCall bootstrap.

The prior tests accepting incomplete-NAV exits, removal of unreadable providers,
automatic removal of an entry provider and repeat recovery fees were deliberately
updated to the approved requirements. New tests also reject aliased sources in
initialization, preserve one-unit funded positions, require zero before approval
cleanup, detect old mutable source retargeting, and reject public/low-HWM/repeated
migration initialization. Fifty-year fee settlement and subsequent fee changes,
deposits and treasury withdrawal remain defined with a positive denominator.

Independent cross-review follow-ups also preserve nonzero receipt claims whose
NAV rounds to zero, include idle underlying in NAV/HWM and withdrawal liquidity,
and allow cash recovery after all provider assets were lost without charging a
recovery performance fee. Even sufficient idle cash cannot bypass an unknown
funded provider's strict valuation gate.

## Future production migration (not executed)

1. Attest the actual deployed implementation, storage baseline, provider/source
   identities, roles, aliases, outstanding balances and historical per-share HWM.
   Do not infer these from branch names or the current registry alone.
2. Existing proxies have zero appended fields and fail closed until migrated.
   Use authorized ProxyAdmin upgradeAndCall with
   initializeSecurityAccounting(historicalHighWaterMark). The actual ProxyAdmin
   or configured timelock may bootstrap; random callers cannot. The supplied mark
   must be positive and at least current PPS. An unrecorded historical peak cannot
   be reconstructed automatically. Unsettled old fees are explicitly waived at
   migration and the accrual clock restarts.
3. Resolve preexisting alias configurations and already-retargeted registry
   identities before migration; the new guards refuse to hide these conditions.
   Immutable source registries require new registry/adapter deployments and an
   explicit timelocked empty-position migration, not a hot source replacement.
4. Original nonupgradeable ProviderManager instances are not magically patched.
   Vault pins detect their drift and block valuation/settlement; restore the
   attested source before recovery. Adopt write-once registries for new instances.
5. Full fork tests and deployed-bytecode comparison require separately authorized
   deployment evidence. No live migration or security release is claimed here.

An unknown provider can still reduce availability. That is intentional: a silent
zero plus irreversible share burn loses principal. No emergency partial-claim
product is introduced. Fee cap NAV-minus-one permits severe dilution after very
long inactivity, but never an undefined denominator; normal documented fee
economics and governance controls remain applicable.

Machine-specific reproducible runners and full logs are kept in the workspace
changes/security-remediation-2026-10-27/tracks/optimized directory. Independent
QA/Security review is tracked by the root orchestrator separately from this
implementer verification.
