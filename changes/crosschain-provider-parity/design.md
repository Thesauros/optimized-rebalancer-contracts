---
title: Cross-chain provider parity design
date: 2026-11-22
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Design: crosschain-provider-parity

Evidence and measured venue data are in `research.md`. This file records only
the decisions.

## Reuse over redeploy

Where the standalone vault already runs a provider that the cross-chain
strategy can use, the strategy reuses the deployed instance instead of
deploying a new one. This is what Base and Arbitrum do for Aave and Morpho, and
it is what Ethereum now does for `AaveV3Provider 0x107DA8Bd…6941`.

The property that makes reuse safe is structural, not incidental: the provider
is delegatecalled by the Rebalancer, so its code runs in the strategy's context
and its position accrues to the strategy, while the provider contract itself
holds no reference to any vault. `AaveV3Provider` has exactly one immutable,
the PoolAddressesProvider, and takes `IRebalancer vault` as an argument on
every method. `FluidProvider` and `MorphoV2Provider` are the opposite shape —
they pin their source in the constructor and assert the delegatecall context in
`_checkVault` — so those are deployed fresh per strategy.

Consequence for the registry: a reused provider goes in `reusedProviders` and
must have a matching `deployments/<net>/<Label>Provider.json`, which
`ops/test/registry.test.ts` checks. A fresh provider goes in `comet`,
`fluidFToken` or `morphoV2Vault` and phase 1 deploys it.

## Provider order

`strategyProviders` fixes the order: entry provider first, fresh Compound
second, remaining reused providers, fresh Fluid, fresh Morpho V2. AaveV3 is
appended to Ethereum's `reusedProviders` rather than inserted, so Steakhouse
stays the entry provider and deposits keep landing where they land today.
Changing the entry provider would move every deposit, which is a governance
decision and not part of provider parity.

`Rebalancer.setProviders` rejects two providers whose `getSource` collides.
Aave's source is the Pool, Compound's the Comet, Morpho V1's the MetaMorpho
vault, Morpho V2's the V2 vault, Fluid's the fToken, so the Ethereum set of
seven has seven distinct sources. `testWiringMatchesTheRegistry` asserts each
pinned source explicitly.

## Caps

Caps are not invented. Every cap added here copies the value the same provider
label already carries on another chain: Fluid 3000 as on Base and Ethereum,
GauntletPrimeV2Morpho 2000 as on Base.

`AaveV3: 0` on Ethereum is the exception and is called out in the registry
comment. Zero means uncapped. On Base and Arbitrum AaveV3 is the entry
provider, where uncapped is structurally required — every deposit lands there
first, so a cap would make allocations revert. On Ethereum the entry is
Steakhouse, so an uncapped Aave is a risk posture rather than a necessity. It
is defensible: the Aave V3 Ethereum USDC market holds 4.16 billion USDC, far
larger than anything this vault can route. It is flagged for confirmation
rather than silently chosen.

## Per-chain fork coverage instead of a shared abstraction

`FluidProvider.t.sol` gains a second concrete contract for Arbitrum instead of
being refactored into an abstract base with per-chain configs, which is the
shape `GauntletV2MorphoProvider.t.sol` uses.

The reason is the tolerance constants. `FLUID_TOLERANCE` is calibrated against
measured mainnet drift and its comment records the blocks it was measured over.
Folding that into a shared base would either apply Ethereum's calibration to
Arbitrum or force the base to carry per-chain tolerances, which is more
machinery than a second contract. The duplicate is additive: the existing
Ethereum contract is untouched and still passes.

The test that justifies the per-chain copy is
`testRateIsTheAccrualOfTheSupplyExchangePrice`. `FluidProvider` reads the
supply exchange price out of the Liquidity layer's storage, so a chain whose
Fluid deployment differs in layout would misprice yield silently rather than
revert. Base and Ethereum each prove their own layout; Arbitrum now proves its.

## What is deliberately not done here

No transaction touches a live contract. Deploying the Ethereum, Monad, Plasma
or Solana spoke, registering Fluid on the live Arbitrum strategy, changing a
deployed cap and rotating governance are all governance actions needing
separate authorization. The registry change plus fork tests make each of them
executable and verifiable; none of them is executed.
