---
title: Fluid provider verification
date: 2026-11-05
status: local-validation
project: optimized-rebalancer-contracts
author: cto-agent
---

Branch `feat/ts-420-fluid-ethereum` from the TS-419 commit 967baab. No live
network, deployment, governance transaction or push. Foundry 1.8.7, solc
0.8.33. Fork tests ran on `eth.drpc.org` (archive): the default
publicnode endpoint serves only recent state and stalled the suite.

| Check | Result |
|---|---|
| `FluidProvider.t.sol` (Ethereum fork) | 6/6 |
| `CrossChainStrategyEthereum.t.sol` with five providers | 4/4 |
| Foundry, non-fork suites | 176/176 |
| ops tests | 49/50; the failure is the one on main (`scripts/extract-errors.js` is missing from the repository) |
| `tsc` | only the `node:sqlite` error main has |
| `FluidProvider` compile warnings | none |

What the fork tests establish:

- The rate equals the observed growth of Fluid's own supply exchange price
  (`fToken.getData()`) over 30 days with no transaction in between, within
  0.1% relative. Fluid's LiquidityResolver differs by about 0.01% (4.57%
  against 4.58%) because it uses current totals; it is not the accrual rate.
- The balance view accrues without a transaction and equals
  `previewRedeem`; a deposit of 10 000 USDC redeems with interest.
- The constructor reverts for a codeless address (`InvalidFToken`) and for a
  generic ERC4626 (MetaMorpho has no `getData()`); direct calls outside the
  vault revert (`InvalidVaultContext`).
- Rebalancing Fluid <-> Steakhouse keeps NAV; the strategy built as phase 1
  builds it spreads 20% into Fluid and refuses 35% (cap 30%).

Found while testing: `makeAddr("eoa")` carries an EIP-7702 delegation on
mainnet (its key is public), so a codeless address needs an explicit check.

## Not verified here

The three-fork rehearsal was not re-run for this change: public RPCs failed
the TS-419 runs at different points (see that change's verification), and the
paths it would add are covered above. Run it with a paid archive Ethereum RPC
(`ETHEREUM_FORK_URL`) before deployment. An independent review of
`FluidProvider` is pending; it is the first new provider contract in this
series.
