---
title: Services keep working while a strategy provider view fails
date: 2026-11-07
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Change: convert-to-assets-view-fix

Since the complete-NAV remediation, `Rebalancer.totalAssets()` and everything
built on it (`convertToAssets`, `previewRedeem`, `getAccruedFees`) revert
`ProviderUnavailable` while any provider's balance view fails. The ops services
called `convertToAssets` unconditionally, so one failing view on one chain would
stop every Tick of the vault (and with it settlement and instant exits after
`maxTickAge`), crash the keeper's recall, the monitor pass, the indexer's
allocation and `exec status`. The NAV rule for an unhealthy strategy
(docs/nav-reproduction.md) assumed `convertToAssets` under-states instead.

## Required behavior

1. NAV and the independent verifier value a strategy position whose
   `providersHealthy()` is false at the reference block at its readable lower
   bound: the contract's conversion with every failing provider counted as 0,
   computed from public getters; offer = max(bid, previous accepted offer).
2. With every provider readable the bound equals `convertToAssets` exactly.
3. A provider counts as failing exactly when the contract would leave it out
   (no pinned source, `getSource` differs or reverts, `getDepositBalance`
   reverts or exceeds the 3 M gas stipend). An RPC failure is never priced as a
   failing provider.
4. Strategies on the implementation before the remediation (live Base and
   Arbitrum) keep their own `convertToAssets`, which already under-states.
5. Monitor reports the failing providers without aborting its pass; keeper
   recalls the agent's idle and keeps claiming; indexer and `exec status` show
   the bound; `exec deallocate-all` refuses with the reason.

## Acceptance

- Foundry: the conversion on public getters equals `convertToAssets` and
  `getAccruedFees` (fuzzed); pinned golden vectors; a failing view reverts the
  complete-NAV views but leaves every input readable; a retargeted source is
  left out.
- ops: the TypeScript mirror reproduces the golden vectors; the unhealthy path,
  source pinning, out-of-gas, RPC failures, foreign reverts and the old
  implementation; `positionsAt` keeps committing with the offer rule.

## Out of scope

Contract changes; making `totalAssets` non-reverting; changing what the
contract counts as a failing provider.
