---
title: Base cross-chain Strategy upgrade with Fluid and Gauntlet Morpho V2
date: 2026-11-12
status: active
project: optimized-rebalancer-contracts
author: product-agent
---

# Change: base-crosschain-upgrade

Research: `changes/base-crosschain-upgrade/research.md`.
Prepare one new branch from main `32f7dcf62ae3b30775daa1ed8d8fc735c00169b4`
for Base (chain ID 8453). Implement and locally verify three capabilities:
upgrade the existing cross-chain Strategy implementation, append Fluid, and
append Gauntlet Morpho V2. Public deployment, upgrade, governance execution,
allocation and service restart are not authorized by this preparation task.

# Requirements

1. **Existing deployment.** Use the Base cross-chain manifest, attest actual
   implementation/admin/runtime and current configuration from a pinned block.
   Preserve the Strategy proxy, EpochVault, TickAccountant and ChainAgent
   identities. Reject another chain or unexpected deployment drift.
2. **Atomic migration.** Build the current main Rebalancer with pinned compiler,
   settings and dependencies. Verify the deployed storage prefix and inherited
   namespaces. Upgrade through the actual ProxyAdmin with
   `initializeSecurityAccounting(historicalHighWaterMark)` in the same call.
   Require explicit governance-attested HWM, positive and at least the fresh
   ceiling PPS. Record provenance and legacy-fee treatment. A current/fork PPS
   used for a test is not an attestation or an execution input.
3. **Fluid on Base.** Reuse the immutable FluidProvider integration and verify
   its Base fUSDC source and USDC asset on-chain. Include provider deployment,
   configuration and governance preparation for this existing Strategy.
4. **Gauntlet Morpho V2 on Base.** Reuse MorphoV2Provider and verify the intended
   Gauntlet V2 source, asset and V2 interface on-chain. Treat it as an additional
   venue; retain the existing Gauntlet Core Morpho provider and funded position.
5. **Preservation.** Append the two distinct new venues to the five existing
   providers, preserving existing order, current entry, caps, fees, treasury,
   roles, holders and balances. Keep source pins correct. Do not reset a funded
   position, remove a provider or silently choose a new allocation/entry.
   New-provider caps must be explicit in the reviewed plan; unknown values stay
   unresolved draft inputs rather than silently becoming uncapped.
6. **Operations.** Keep provider labels/order, valuation, ABI, manifests and
   monitoring/config checks consistent with the candidate. Preserve the current
   NAV freshness and failure semantics. Document the required compatible ops
   release; local verification does not attest the remote service revision.
7. **Reviewable release.** Produce reproducible build/fork evidence and a staged
   Base deployment/governance plan with targets, calldata, code/source hashes,
   actual delay/authority, estimates and postconditions. Separate executable
   inputs from missing attestations/undeployed addresses. No placeholder HWM or
   target address may be presented as a signable transaction bundle.

# Acceptance

| ID | Given / when | Required result |
| --- | --- | --- |
| AC1 | Wrong chain, stale implementation or mismatched runtime/source | Preparation fails before producing an execution-ready bundle. |
| AC2 | Current deployed Base Strategy on an isolated fork; atomic upgrade/initialization | All legacy storage fields and balances remain; HWM/source pins initialize; healthy NAV and expected fee baseline are established. |
| AC3 | Bare upgrade, unauthorized/zero/too-low/repeated initializer | Rejected or settlement blocked as documented; no public initialization window. |
| AC4 | Two new provider deployments and Timelock registration on the Base fork | Seven distinct providers; original five order/positions, entry, caps and permissions preserved; exact delay enforced. |
| AC5 | Small isolated deposit/withdraw round trip through each new venue | Balance/NAV reconcile within documented protocol rounding; original positions restored/preserved; unsupported sources and wrong asset rejected. |
| AC6 | Allocation/deallocation, return-to-vault and user payout with usable NAV | Existing paths remain functional and no accounting or holder-value regression is introduced. An existing stale Tick is reported independently. |
| AC7 | Candidate ops observes the resulting seven-provider Strategy | Correct source labels/order and valuation; no silent zero for unknown NAV; clean focused tests and typecheck. |
| AC8 | Missing HWM attestation, source evidence, deployment address or cap | Draft plan names the missing input and remains non-signable; local implementation work can still complete. |
| AC9 | Task concludes | No public transaction/service restart; local fork mutations reverted and nodes stopped; QA/security verdicts and remaining release inputs recorded. |

# Scope and rollout

Exclude Arbitrum/Ethereum/Solana changes, cross-chain expansion, unrelated
economic/role/buffer changes and ProviderManager/CCTP replacement. Any such
migration is a separately justified scope decision. Existing EpochVault,
EpochVaultLogic, TickAccountant and ChainAgent have no source-upgrade requirement
for this Strategy target.

Stage: snapshot and preflight -> source/runtime/storage verification -> local
provider deployment and atomic Strategy migration -> delayed provider
registration -> functional/ops verification -> independent QA/security ->
concrete human-reviewed release bundle. Execution requires separate authority.
Keep new venues unused until their registration/valuation checks pass; rollback
instructions must account for initialized security state and any funded new
venue rather than blindly restoring the legacy implementation.

# Human validation

| Stage | Reviewer | Criterion |
| --- | --- | --- |
| Scope | User and implementation owner | The three named capabilities are covered on Base only. |
| Migration input | Governance owner | Historical HWM and fee treatment explicitly attested. |
| Pre-release | User, QA and Security | Exact source/deployment/governance evidence; critical/high findings resolved. |
| Public execution | User/governance signer | Separately approved concrete transaction bundle and funding. |
| Post-release | Operator | Fresh valid NAV, expected seven sources and successful allocation/exit checks. |

Definition of done for this branch: implemented preparation/configuration,
focused passing tests and actual-state fork evidence against this SDD, with
explicitly separated execution blockers. A prepared branch is not a production
release claim.
