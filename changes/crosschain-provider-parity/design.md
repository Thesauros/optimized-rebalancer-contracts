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

**Arbitrum, handed to `feat/arbitrum-crosschain-upgrade`.** That branch appeared
on the remote during this work and covers the same ground more thoroughly: exact
Paris creation-bytecode verification for all three candidates, a historical
settled-state ceiling PPS reconstruction of `1005053181914548924` from the full
event history, a scoped unsigned preparation CLI in
`scripts/prepare-arbitrum-crosschain-upgrade.ts`, a fork suite pinned at block
526524948, and a gas-funding analysis. Duplicating it here would only create a
conflict, so this change no longer touches the `arbitrum` registry entry and the
rehearsal fork test written earlier has been removed.

Both efforts independently derived the same two addresses, which is the useful
cross-check: Fluid fUSDC `0x1A996cb54bb95462040408C06122D45D6Cdb6096` and Morpho
Vault V2 `0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78`. The disagreement is only
about whether the V2 vault should be registered at all.

What this change keeps for Arbitrum is one check that branch does not have.
`FluidProviderArbitrumForkTest.testRateIsTheAccrualOfTheSupplyExchangePrice`
skips 30 days on a fork and asserts the rate `FluidProvider` reports equals the
observed accrual of the Arbitrum Liquidity layer's supply exchange price.
`FluidProvider` reads that price out of storage, so a chain whose Fluid
deployment differed in layout would misprice yield silently rather than revert.
Their suite asserts `getDepositRate > 0`, which a wrong layout would also pass.
Base and Ethereum each prove their own layout; this proves Arbitrum's.

Two measurements this change contributes to that branch's decision, neither of
which appears in its report. First, the Arbitrum V2 vault holds **191,941 USDC**
and its four underlying Morpho markets run at about 91% utilisation, against
284,480,245 USDC for the Base vault the caps are copied from. The whole Arbitrum
Gauntlet USDC V2 complex, Prime plus Balanced, is about 335k. A 2000 bps cap is
a fraction of the spoke's NAV, not of the venue's capacity, so it does not bound
this exposure. Second, `utils/constants.ts` carries no `version: 2` entry for
chainId 42161, so that branch's `morphoV2Vault` is not backed by the table the
Base entry is checked against.

Their own report notes the allocator cannot use either venue yet: "The existing
allocator still lacks Fluid/Morpho V2 market readers and registry support.
Registering adapters alone does not enable allocation into these markets." So
registration is not the enabling step, and the depth question can be settled
before capital is at risk rather than after.

**Ethereum spoke.** Registry is complete at seven providers. Remaining work is
operational: run phases 1 to 5, produce
`deployments/mainnet/crosschain.json`, add the chain to
`TickAccountant.chainIds()` through the hub Timelock, and declare routes in both
directions. Phase 5 derives the hub chain set from the registry, and
`TickAccountant._setChains` has no guard against dropping a chain, so the plan
must be built from the full registry rather than a narrowed one. Adding
Ethereum also closes one of the three open phase-4 failures.

**Monad.** Registered. `AaveV3Provider 0xAeEcf7F7…24e0` is reused from the
standalone vault, CCTP domain 15 is live, and the Aave USDC market is active
with 86M USDC supplied. `chainConfigs[143]` already carried the chain with
`cometPairs: []` and `morphoVaults: []`, so the entry names AaveV3 as the sole
and therefore entry provider and sets no `comet`, `fluidFToken` or
`morphoV2Vault`; Fluid publishes no Monad deployment at all, so Monad is
Aave-only until that changes. `base.routes` gained `'143'` in the same commit,
because the ops test asserts routes are bidirectional.

Two things about Monad were measured rather than assumed. Its RPC serves archive
state, unlike the Ethereum and Arbitrum endpoints, so `ForkPins.MONAD` is a real
pin at block 124_400_000 and the suite is reproducible as shipped. And forge
1.10.0 will not build a Monad fork inside an Ethereum EVM, so the suite needs
`--rpc-url` and `--fork-block-number` on the command line; without
`MONAD_RPC_URL` it reports SKIPPED rather than passing vacuously.

`confirmations` is 20, which at Monad's measured 0.307 s block time is the same
~6 s wall-clock depth Arbitrum's 20 gives at 0.284 s. Monad reorg behaviour is
not observed yet, so this is the closest analogue rather than a measured value,
and the registry comment says so. Bridged funds do not depend on it.

What remains is operational and needs authorization: phases 1 to 3 on Monad,
then the hub Timelock batch adding 143 to `TickAccountant.chainIds()` with the
peer, remote and route in both directions. Note that the governance Safe does
not exist on Monad, so the `production` profile gate in `01-deploy.ts` would
refuse; only `stand` can deploy there today. The deployer holds 13.03 MON and
3.04 USDC, enough for the 1 USDC seed.

**Solana.** Source is complete in `main` and CI builds both programs with
`cargo build-sbf --arch v2` and runs the local-validator suite. This change
prepares activation only: no keypair is generated, nothing is built or deployed,
because every remaining prerequisite is a custody decision rather than code.

Decisions that gate everything else, in the order they block:

1. **Deployment identity.** The program ID in source is a build identity, not a
   deployed program. Generating the deployment keypair, updating `declare_id!`
   and rebuilding verifiably in the pinned image decides the address every PDA
   derives from, so it cannot be revisited later.
2. **Authority.** Program upgrade authority and native governance go under the
   reviewed timelocked multisig PDA. The EOAs in the local VM tests are test
   identities and are not a governance recommendation.
3. **Cluster and SBPF version.** SBPF v3 build compatibility is a separate check
   from the v2 testing CI already does.
4. **Public config.** `governance`, `executor`, `guardian`, `maxPerTransfer`,
   `capacity`, `refillPerSecond`, `maxFeeBps` and `strategyCaps` keyed by
   reserve. Amounts are integer strings in USDC micro-units and identities are
   public keys.

Then the sequence, with the working directory made explicit because the `solana`
script lives in `ops/package.json` and fails from the repository root:

1. Build verifiably, record the base58 `programDataSha256` over deployed
   ProgramData bytes after the 45-byte loader header including reserved zero
   padding, and check it against the reviewed build. Native readers verify that
   digest at startup and periodically, so a wrong digest fails closed later
   rather than at deploy time.
2. Write the manifest against the `SolanaManifest` interface in
   `deploy/crosschain/native-registry.ts`: `family`, `network`, reviewed program
   ID, bytes32 seed, derived agent and idle PDAs, Base hub agent, the new native
   `hubAdapter` address, `maxCheckpointAgeSeconds`, `programDataSha256` and the
   explicit `{ protocol: 'kamino-lending', reserve, market }` entries. The
   registry already carries the main-market USDC reserve
   `D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59` in market
   `7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF`; check owner, mint, market and
   native token program before trusting it. Do not set `localValidator` on a
   mainnet manifest.
3. `cd ops && npm run solana -- prepare public-config.json` for the unsigned
   native initialization, collateral ATA and strategy registration
   instructions, plus the address lookup table. The table uses a recent slot, so
   regenerate immediately before execution, run the extension batches in order,
   and wait for activation before setting `SOLANA_LOOKUP_TABLES`.
4. `cd ops && npm run solana -- plan public-config.json` for the EVM adapter's
   constructor parameters and the unsigned Base Timelock calldata. The native
   adapter's endpoints are immutable, so a wrong endpoint means a new adapter
   and route rather than a fix.
5. Deploy and verify the adapter, native agent, strategies and the first
   checkpoint. Only then activate the chain in the Base accountant and unpause
   the native agent through its governance.
6. Run one separately authorized capped round trip and a full unwind before
   raising any limit.

The ordering in step 5 is forced by the code, not by preference:
`loadNativeSpokes()` returns nothing unless `CROSSCHAIN_SOLANA_MANIFEST` is set,
and an accountant tracking Solana without its configured native reader fails
closed. So every service needs `CROSSCHAIN_SOLANA_MANIFEST`, `RPC_SOLANA` with
finalized and historical support, and the executor, relayer and checkpoint
keypair file paths configured before the hub chain set changes, not after.
Solana's accounting id is `0x8000000000000005`, which is what the hub accountant
will gain.

One verification item stays open. Circle's two mainnet programs,
`CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe` and
`CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC`, are not repository artifacts, so
the bridge assertions are skipped until `CCTP_MAINNET_DUMP=true` is run once and
its output is kept alongside the dated verification report.
`specs/solana-kamino-crosschain/verification.md` already records mainnet bytecode
hashes for both, so this is a re-run and archive step rather than new research.

**Plasma: deferred.** Decided 2026-11-22 on the evidence in `research.md`. Not
registered, and the reason is not the bridge: a USDC spoke could receive funds
and could not return them, because the whole chain's USDC exit capacity is one
EOA-controlled pool holding about 30k USDC. Revisit only if that liquidity
materially changes, if a real USDC yield venue appears on Plasma, or if the
product decides on a USDT0-denominated spoke with an FX rule in NAV.

**Cross-cutting.** Three things are prerequisites for any of the above going
live rather than follow-ups: redeploying the monitoring service so the live Base
Morpho V2 position is valued with V2 math, closing the two remaining phase-4
failures, and rotating the stand's governance off the single deployer EOA
before it holds material value.

Two `ops/src/util.ts` defects should be fixed before Monad goes live, and are
deliberately not fixed in this change because they touch the running monitor's
log scanning and deserve their own tests. `logStep` is a module global shared by
every chain in the process, so Monad's roughly 101-block `eth_getLogs` cap would
drag the step down for Base, Arbitrum and Ethereum in the same monitor or
indexer process and multiply their request counts against the shared pacers. And
`providerRangeLimit` does not recognise Plasma's
`eth_getLogs is limited to a 10,000 range` error, so `scanMany` rethrows instead
of halving; that only bites if `LOG_RANGE` is raised above the 9000 default, and
Plasma is deferred, so it is not urgent.

