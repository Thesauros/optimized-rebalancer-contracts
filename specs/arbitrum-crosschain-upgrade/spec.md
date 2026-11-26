---
title: Arbitrum cross-chain Strategy upgrade with Fluid and Gauntlet Morpho V2
date: 2026-11-22
status: active
project: optimized-rebalancer-contracts
author: implementation-agent
---

# Change: arbitrum-crosschain-upgrade

Prepare the Arbitrum-only counterpart to `base-crosschain-upgrade` from main
`2fb3978f2db6bdfbfe51fd35345a9190f500b36d`. Upgrade the existing Strategy
implementation and append two verified native-USDC venues. Research is in
`changes/arbitrum-crosschain-upgrade/research.md`; operator instructions are in
`docs/arbitrum-crosschain-upgrade.md`. Preparation and isolated simulation do not
constitute public deployment, governance execution or production readiness.

## Requirements

1. **Pinned target.** Accept only chain 42161, Strategy
   `0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71` and native USDC
   `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`. Reject implementation/runtime,
   provider order, source, entry or cap drift at a canonical snapshot block.
2. **Atomic accounting migration.** Use the reviewed main Rebalancer build,
   preserve its deployed storage prefix and upgrade through the actual
   ProxyAdmin with `initializeSecurityAccounting(historicalHwm)` in the same
   transaction. Require an explicit historical HWM, evidence/attestations and
   legacy-fee-waiver acceptance. Never infer historical HWM from current PPS.
3. **Two actual adapters.** Prepare fresh Arbitrum `FluidProvider` and
   `MorphoV2Provider` deployments against the verified fUSDC and Gauntlet USDC
   Prime V2 sources. Check asset, constructor interfaces, exact deployed runtime,
   immutable sources and applicable V2 gates. Source vault addresses are not
   provider adapter addresses. V1 and V2 remain distinct.
4. **Preservation.** Keep all five existing providers in order and preserve
   holdings, receipt claims, Aave entry, existing caps, proxy identities,
   treasury, fee rates and roles. Append two distinct sources, without an implied
   allocation. Proposed caps are 3000/2000 bps and must be explicit reviewed inputs.
5. **Governance.** Use the current Arbitrum Timelock owner and delay, observed as
   24 hours. Bind queue/execute/cancel to identical tuples and IDs. Install both
   new caps after registration before any allocation into either venue.
6. **Operations.** Preserve existing NAV freshness and failure semantics. The
   inspected allocator currently lacks Fluid/V2 support: no production rollout or
   new-venue allocation until compatible readers, registry and valuation have
   passed their own checks. Do not activate extra networks through a broad main
   registry rollout. Local tests do not attest remote runtime compatibility.
7. **Reviewable preparation.** Missing deployed addresses, verified runtimes,
   HWM/evidence, fee acceptance or caps produce `DRAFT_NOT_SIGNABLE`, a null atomic
   upgrade and no governance calls. Constructor-only plans may still be emitted.
   No signer, broadcast, public-chain mutation or fabricated execution input.

## Acceptance criteria

| ID | Scenario | Required result |
| --- | --- | --- |
| AC1 | Wrong chain/USDC generation/proxy, or legacy configuration drift | Fail before producing a reviewable execution bundle. |
| AC2 | Missing any release input or actual candidate deployment | Explicit draft blockers; no upgrade/governance calldata. |
| AC3 | Actual-state Arbitrum fork, atomic migration | Existing storage/holdings/roles/fees preserved; HWM and sources initialized. |
| AC4 | Bare upgrade or unauthorized, zero, too-low or repeated initialization | Reject or remain financially blocked as designed. |
| AC5 | Delayed registration and caps on the fork | Early execution rejected; seven distinct providers in order; five prior positions and entry preserved. |
| AC6 | Normal round trips through both new venues | Actual received USDC and remaining shares reconcile with documented rounding; no forced deallocation. |
| AC7 | Native asset and share decimals differ | Six-decimal USDC and protocol share previews handled without treating raw V2 shares as USDC. |
| AC8 | Unknown NAV, unavailable liquidity or stale Tick | No zero-balance substitution, stale-Tick bypass or claim of guaranteed immediate withdrawal. |
| AC9 | Operational release | Compatibility established before rollout/allocation; current services are not assumed ready. |
| AC10 | Evidence and task completion | Actual tests/block/source/limits reported; no claim that unsigned preparation completed a public transaction. |

## Scope boundaries

Only the local Arbitrum ChainAgent is attested as preserved alongside its Strategy.
All Base hub contracts remain unchanged. Exclude ProviderManager/CCTP migrations,
additional networks, external protocol upgrades, new roles, fee rates and buffer
policy. Existing contracts must not be replaced merely because of deployment age.

Use `test/forking/ArbitrumStrategyUpgrade.t.sol` with an explicit
`ARBITRUM_FORK_BLOCK`. Publish only actual verification results; retain unresolved
release inputs. After initialization/funding, rollback must account for the live
security state and receipt claims rather than reinstalling legacy code blindly.
