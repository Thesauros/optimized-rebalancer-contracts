---
title: Fluid on Ethereum in the cross-chain strategy
date: 2026-11-05
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Change: ts-420-ethereum-fluid-provider

Task TS-420. Add Fluid lending (fUSDC) to the Ethereum strategy of the
cross-chain vault added by TS-419. No Fluid provider exists in the repository,
so this change adds one.

## Required behavior

1. `FluidProvider` implements `IProvider` over a Fluid fToken: deposit and
   withdraw through the fToken in the Rebalancer's delegatecall context only,
   balance as the fToken's preview of the held shares, source = the fToken.
2. `getDepositRate` returns, in ray, the rate the Fluid Liquidity supply
   exchange price accrues at; fToken rewards are not counted.
3. The constructor rejects an address that is not a Fluid fToken before any
   approval can be made to it. Configuration is immutable.
4. The registry entry `mainnet` names the fToken; phase 1 deploys a fresh
   `FluidProvider` and initializes the strategy with it last; phases 2, 4 and 5
   handle its cap like any other provider.
5. One function gives the provider order and labels to every phase.

## Acceptance

- Fork tests on Ethereum: wiring and pinned source; constructor rejects a
  codeless address and a generic ERC4626; direct calls outside the vault
  revert; the rate equals the observed accrual of Fluid's supply exchange
  price; a deposit accrues in the view and exits fully; rebalancing between
  Fluid and Morpho keeps NAV; the Ethereum strategy with five providers
  respects the Fluid cap.
- ops tests: provider order and labels per network.

## Out of scope

Adding Fluid to a strategy already initialized without it (a Timelock
`setProviders` call, documented), Fluid rewards, Fluid on other chains.
