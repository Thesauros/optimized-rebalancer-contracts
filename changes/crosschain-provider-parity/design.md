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

## Stage plan for the remaining networks

Ordering follows one rule: a network is added only when every fact it depends on
is measured, and a live spoke is only extended after its registry entry has been
fork-tested.

**Arbitrum Fluid, live.** The registry entry is in; the live spoke
`0xD211Bf…2B71` still runs five providers. Registering Fluid there is a
Timelock `setProviders` with all six plus a `setProviderCap` at 3000, which is
the sequence `BaseStrategyExpansionForkTest` already replays against the live
Base strategy. What is missing is the Arbitrum equivalent of that replay: a
fork test that loads the real Arbitrum spoke, extends it through its own
Timelock and round-trips USDC through Fluid. Until that passes, the live spoke
is unchanged.

**Ethereum spoke.** Registry is complete at seven providers. Remaining work is
operational: run phases 1 to 5, produce
`deployments/mainnet/crosschain.json`, add the chain to
`TickAccountant.chainIds()` through the hub Timelock, and declare routes in both
directions. Phase 5 derives the hub chain set from the registry, and
`TickAccountant._setChains` has no guard against dropping a chain, so the plan
must be built from the full registry rather than a narrowed one. Adding
Ethereum also closes one of the three open phase-4 failures.

**Monad.** AaveV3Provider `0xAeEcf7F7…24e0` is reusable and its USDC market is
active with 86M USDC. CCTP domain 15 is live. `chainConfigs[143]` already
carries the chain with `cometPairs: []` and `morphoVaults: []`, so the registry
entry names AaveV3 as the sole and therefore entry provider, sets no `comet`,
no `fluidFToken` and no `morphoV2Vault`, and the ops test that requires an
absent Comet to match an empty `cometPairs` passes unchanged. Fluid publishes no
Monad deployment, so Monad is Aave-only until that changes. Blocker to clear
first: whether `https://rpc.monad.xyz` serves the archive state a pinned fork
test needs.

**Plasma.** CCTP domain 33 is live and native USDC exists, but the asset
question is unresolved and gates everything else. A USDC spoke has no Aave
market and only a Fluid fUSDC holding 0.017 USDC; the deep venue, 470M, is
USDT0, which CCTP does not deliver and `TickAccountant` cannot price without an
FX rule. Adding Plasma to the registry before that is chosen would encode a
guess. The decision and its evidence belong in a separate proposal.

**Solana.** Source is complete in `main` and CI builds both programs with
`cargo build-sbf --arch v2` and runs the local-validator suite. Activation is a
manual gate with prerequisites that are custody decisions rather than code:
generate the deployment keypair, set it in `declare_id!`, rebuild verifiably in
the pinned image and record the base58 `programDataSha256`, then write the
manifest with the reviewed program ID, the derived agent and idle PDAs and the
Kamino reserve and market. On the hub side, register `CctpSolanaAdapter`, add
the peer and route, and extend the accountant chain set. Circle's two mainnet
programs are not repository artifacts, so the bridge assertions stay skipped
until `CCTP_MAINNET_DUMP=true` is run once and its output kept with the dated
verification report. `solana-cli` 4.4.1 and `cargo` 1.98 are present on this
machine; `anchor` is not installable here, which does not matter because the
programs are native, and SBPF v3 build compatibility is a separate check from
the v2 testing already done.

**Cross-cutting.** Three things are prerequisites for any of the above going
live rather than follow-ups: redeploying the monitoring service so the live Base
Morpho V2 position is valued with V2 math, closing the two remaining phase-4
failures, and rotating the stand's governance off the single deployer EOA
before it holds material value.

