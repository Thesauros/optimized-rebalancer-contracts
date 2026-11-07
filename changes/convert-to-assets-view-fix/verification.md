---
title: Readable strategy valuation verification
date: 2026-11-07
status: local-validation
project: optimized-rebalancer-contracts
author: cto-agent
---

Branch `fixes/convertToAssets_view-fix` from `main` 3df4199 (state before TS-419;
`dev` has the same `Rebalancer.sol` and `snapshot.ts`). No contract change, no
deployment, no push. Foundry 1.8.7, solc 0.8.33, Node 22.21.

| Check | Result |
|---|---|
| `test/unit/ReadableStrategyValue.t.sol` | 4/4, fuzz 256 runs |
| Foundry, non-fork suites | 180/180 (176 before + 4) |
| `ops/test/strategy-value.test.ts` | 8/8 |
| ops tests | 49/50; the failure is the one on main (`ops/scripts/extract-errors.js` was deleted in 0c420d3) |
| ABI fragments (incl. the new strategy getters) vs compiled Rebalancer | pass |
| `tsc -p ops` (src and tests) | only the `node:sqlite` error main has |

What the tests establish:

- On the current Rebalancer a failing view reverts `convertToAssets`,
  `totalAssets` and `getAccruedFees`, while every input of the bound stays
  readable (providers, pinned sources, `getSource`, fee getters, supply).
- The bound on public getters equals `convertToAssets` and `getAccruedFees`
  for any fees (up to the caps), elapsed time (up to 5 years), yield and share
  amount: Solidity fuzz.
- Golden vectors (2%/20% fees, 30 days, 50 USDC yield): 1 038 579 285 with every
  provider; 649 280 583 with provider B (400 USDC) failing. The TypeScript port
  reproduces both, fee shares included.
- `positionsAt` with a failing view: bid 649 280 583, offer = previous accepted
  offer when higher, never below bid; the strategy listed as unhealthy. With
  the old `positionsAt` restored, that test fails (the regression is caught).
- Left out like the contract: retargeted source, unpinned provider, out-of-gas
  view. Not left out: rate-limit and header errors, transport timeouts
  (propagate); a foreign revert of `convertToAssets` propagates.
- Old implementation (live Base/Arbitrum): its own `convertToAssets` is used;
  the monitor still names the failing provider.

On-chain check (2026-11-07): the live Base strategy
`0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33` and Arbitrum strategy
`0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71` revert `getPinnedProviderSource`
and `getHighWaterMark` (implementation before the remediation), fees 0.

Not verified here: a run against a live strategy whose provider view fails
(no such state exists today); the rehearsal (it never breaks a provider).
