---
title: Readable strategy valuation in the ops services
date: 2026-11-07
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

## Where it bit

`ops/src/snapshot.ts` `positionsAt` called `convertToAssets(shares)` before
`providersHealthy()`. On the current Rebalancer (`_convertToAssets` ->
`totalAssets()` -> `_totalAssetsAtProviders()`), a failing view makes that call
revert, `buildSnapshot` throws and no Tick is committed for any chain; the
`unhealthy` branch below it was dead. Same revert in `keeper.ts` (recall),
`monitor.ts` (`totalAssets()` right after the health check), `indexer.ts`
(allocation) and `exec.ts` (status, deallocate-all).

Exposure: the live Base and Arbitrum strategies still run the implementation
from before the remediation (no `getPinnedProviderSource`, no
`getHighWaterMark`; checked on-chain 2026-11-07), where `convertToAssets`
under-states instead. The bug activates with the first strategy on the current
implementation: the Ethereum spoke (TS-419) or an upgrade of Base/Arbitrum.

## Design

`ops/src/strategy-value.ts`:
- `strategyShareValue(strategy, shares, block)`: healthy -> `convertToAssets`
  (unchanged path, same calls). Unhealthy -> try `convertToAssets` (the old
  implementation answers with its own bound); if it reverts with
  `ProviderUnavailable` (or a stripped revert), compute the readable bound.
- `readableTotalAssets`: `_totalAssetsWithHealth` on public getters, with the
  failing providers listed; skips the source check on implementations without
  pinning.
- `accruedFeeShares` / `sharesToAssets`: literal port of `_accruedFees` and
  `_convertToAssetsWithTotals`, rounding included.
- Error classification (`reverted`): ethers maps every JSON-RPC error of an
  eth_call to CALL_EXCEPTION, including rate limits, and its own message always
  says "missing revert data". A provider counts as failing only on revert data
  (ethers extracts it, even "0x", only from a node error reporting a revert) or
  a node message saying revert / out of gas, not transient. Anything else
  propagates, so NAV skips the iteration instead of under-pricing.
- Provider views get `gasLimit = 3_000_000 + 30_000` (stipend plus intrinsic gas).

Consumers: NAV and `verifyTick` through `positionsAt` (one code path, so both
agree); monitor pins one block for all strategy reads, names failing providers,
skips cap checks against an incomplete total; keeper recalls idle only when the
strategy refuses exits; indexer and exec show the bound. Spec:
docs/nav-reproduction.md, "Unhealthy strategy".

## Risks

- The TS port drifting from the contract: pinned by golden vectors in both
  languages and a Solidity fuzz of the same arithmetic against the contract.
- An RPC that answers a failing view with a non-revert error: NAV skips the
  iteration (status quo) rather than mispricing.
- Gas-limit edge: a view needing between the stipend and the stipend plus
  ~9 k gas could be counted on one side and not the other; practical views
  are far below (Smokehouse, the heaviest, uses 1.2 M).
