---
title: Fluid provider design
date: 2026-11-05
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

## Protocol facts (checked on-chain 2026-11-04/05)

| Item | Value |
|---|---|
| fUSDC | `0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33`, ERC4626 over USDC, no proxy (19.6 KB code) |
| Liquidity layer | `0x52Aa899454998Be5b000Ad077a46Bbe360F4e497`, returned by `fToken.getData()` |
| Rewards | `rewardsActive` false; the rate model's program ended 2025-03 |
| `minDeposit` | 2 (USDC units) |
| Withdrawal limit | expand 50% over 21 600 s; supply 132.1 M, limit 66.0 M, withdrawable 22.0 M = the layer's idle USDC |

## Provider

Modeled on `MorphoV2Provider`: immutable fToken, asset and Liquidity address;
`_checkVault` requires the delegatecall context and the vault's asset; no
max* views are used. `getDepositBalance` is `previewRedeem(balanceOf)`, which
Fluid accrues to the current block in the view.

`getDepositRate` reads one packed word, the token's exchange prices and config
(Liquidity mapping slot 5), and evaluates the supply yield of
`LiquidityCalcs.calcExchangePrices`: borrow rate x fee x stored utilization x
the interest-free ratios. That is exactly the rate at which the strategy's
balance grows until Fluid rewrites the word. Fluid's LiquidityResolver reports a
supply rate from the current totals instead of the stored utilization; it
differed by about 0.01% (4.57% against 4.58%), so the test compares against the
observed growth of the exchange price instead. The port is the one validated in
back_tests (TangemLensWide `fluidRate`, accruing variant). Rewards are left out:
an active program would only understate the rate, i.e. make the rebalancer less
eager to move into Fluid.

Gas: deposit 99 k, balance view 15 k, rate view 7 k.

## Registry and phases

`strategy.fluidFToken` in the registry; `strategyProviders(entry, contracts)`
returns the order phase 1 initializes (entry, fresh Compound, other reused,
fresh Fluid) and is used by phases 1, 2, 5 and the phase 4 check, replacing the
three hand-written copies of the Compound special case. `providerLabels(entry)`
serves the registry test. Cap: Fluid 30%, as the other higher-risk Ethereum
venue (Smokehouse); the Liquidity layer is shared by all Fluid products.

## Risks

- New, unaudited contract holding strategy funds through delegatecall.
  Probability: low (small surface, no state); blast radius: the Fluid share,
  at most 30% of the Ethereum strategy. Mitigation: immutable config,
  context check, fork tests; review before deployment.
- Liquidity rate limit: a large exit can revert until the limit expands or
  idle USDC returns. Blast radius: delayed deallocation on Ethereum.
  Mitigation: the cap; the executor withdraws from other providers first.
- Storage-layout dependency: the rate reads Fluid's packed storage. If Fluid
  changes the layout (Liquidity is upgradeable), the rate goes wrong while
  deposits and balances stay correct. Mitigation: the fork test against the
  observed accrual; re-run it on Fluid upgrades.
