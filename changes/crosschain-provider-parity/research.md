---
title: Cross-chain provider parity audit
date: 2026-11-22
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Research: cross-chain provider parity

Audit of what the cross-chain vault must add to match the standalone production
vaults on Base, Arbitrum, Ethereum, Monad, Plasma and Solana.

Method: every figure below was read from the chain on 2026-11-22 through
`eth_call` / `eth_getCode` against public RPCs, or read from a file in this
repository named in the row. Deployment records and docs were treated as claims
to verify, not as sources of truth, and three of them turned out to be wrong.

## Baseline

Work is based on `main` at `2fb3978`. The previously checked out branch
`feat/solana-kamino-crosschain` (`c5e0240`) sits 33 commits behind `main`, its
remote branch is deleted, and its two unique commits are merges whose content
reached `main` by another path. `main` already carries the Solana program and
`CctpSolanaAdapter`, TS-419, TS-420, the crosschain-prod merge and the Base
Fluid + Morpho V2 upgrade.

## Live cross-chain state

Read from the Base hub on 2026-11-22:

| Item | Value |
|---|---|
| `TickAccountant.chainIds()` | `[8453, 42161]` — Base and Arbitrum only |
| `TickAccountant.maxChainExposure()` | `0` (disabled) |
| `ChainAgent.nonce()` | `1` — one outbound send in the hub's life |
| `ChainAgent.isAdapter(CctpV2Adapter)` | `true` |
| EpochVault | `0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6` |
| Strategy | `0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33`, `totalAssets` 25.228018 USDC |
| TickAccountant | `0xB45819B6844708915c5d7936A847186A6a078b27` |
| ChainAgent | `0x3BAf244cAB9a35F75e5F606704Ad7A9D09C16B83`, `idle` 0 |
| CctpV2Adapter | `0x26f9955157CeE02A39B61739abe7A520aB9868ea` |
| Timelock | `0x540cAab5492014084502c1dB6F15644eedCa87ee` |

Live vault limits: `minDeposit` 1 USDC, `maxEpochDeposits` 100,000 USDC,
`minimumBuffer` 0, `minBufferRatio` 1e17 (10%), `maxInstantWithdrawal` 25 USDC,
`dailyInstantLimit` 50 USDC, `instantFee` 2.5e15 (0.25%), `instantMaxTickAge`
7200 s. `maxEpochDeposits` was 500 USDC as of 2026-11-16, so it has been raised
200x since; `registry.ts` still carries neither value for the stand profile.

`EpochVault` exposes no `name()`, `symbol()` or `getProviders()`. Read the
provider set from the Strategy and the chain set from `TickAccountant`.

## Provider matrix

Legacy column read from each standalone vault's `getProviders()`; cross-chain
column read from the spoke Strategy where one is deployed, otherwise from
`deploy/crosschain/registry.ts` on `main`.

| Network | Standalone vault providers | Cross-chain providers | Gap |
|---|---|---|---|
| Base (hub) | 5 — CompoundV3 (entry), AaveV3, SteakhouseHighYield, SteakhousePrime, GauntletCore. `0x3C7739…5beC44`, 1.013858 USDC | 7 live — AaveV3 (entry, cap 0), CompoundV3 5000, GauntletCore 4000, SteakhouseHighYield 3000, SteakhousePrime 4000, Fluid 3000, MorphoV2 GauntletPrime 2000 | none: the cross-chain set is a superset |
| Arbitrum | 5 — CompoundV3 (entry), AaveV3, SteakhouseHighYield, SteakhousePrime, GauntletCore. `0x4E5c0A…76378`, **51,159.893343 USDC** | 5 live — AaveV3 (entry), CompoundV3 5000, GauntletCore 4000, SteakhouseHighYield 3000, SteakhousePrime 4000. `0xD211Bf…2B71`, 3.015028 USDC | parity with the standalone vault; Fluid and Morpho V2 to reach Base |
| Ethereum | 5 — CompoundV3 (entry), **AaveV3**, Steakhouse, GauntletPrime, Smokehouse. `0xc3156D…0Aae3`, 1.007378 USDC | spoke not deployed; registry names 5: Steakhouse (entry), CompoundV3 5000, GauntletPrime 4000, Smokehouse 3000, Fluid 3000 | **AaveV3 absent**, Morpho V2 absent, spoke not deployed, chain not in `chainIds()` |
| Ethereum gen1 | 7 Morpho — Steakhouse, Yearn oevUSDC, GauntletPrime, Gauntlet RWA, Gauntlet Frontier, GauntletCore, Clearstar Yield USDC. `0x839E57…7383`, 9.266187 USDC with third-party shares | none | out of scope: a previous generation, see Open decisions |
| Monad | 1 — AaveV3. `0x40F1fB…4760`, asset USDC `0x754704Bc…`, 1.013292 USDC | absent from both registries and from `chainIds()` | whole spoke plus AaveV3 |
| Plasma | 1 — AaveV3. `0x2Ed9B7…3C99`, asset **USDT0**, 1.012192 USDT0 | absent from both registries and from `chainIds()` | whole spoke, and an asset decision |
| Solana | no standalone vault | source complete in `main`, **not deployed**: no manifest carries `programDataSha256`. One strategy, Kamino Lending, market `7u3HeH…5PfF`, reserve `D6q6wu…gJ59`; capacity 8 strategies per agent | deployment plus activation |

Legacy implementations predate `getProviderCap` — the call reverts on all five
standalone vaults — so caps exist only in the cross-chain generation.

## Bridge feasibility, measured

`registry.ts` hardcodes one pair of CCTP V2 addresses for every EVM chain:
TokenMessenger `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d`, MessageTransmitter
`0x81D40F21F12A8F0E3252Bccb954D722d4c464B64`. Both are deployed on all five
chains with byte-identical runtime code, keccak `0xd2c8d48075d832fb7d07…`, 2175
bytes, and `MessageTransmitter.localDomain()` returns exactly the domain Circle
publishes:

| Chain | `localDomain()` | Circle domain |
|---|---|---|
| Ethereum | 0 | 0 |
| Arbitrum | 3 | 3 |
| Base | 6 | 6 |
| Monad | 15 | 15 |
| Plasma | 33 | 33 |

`docs/crosschain-open-items.md` item B4 and `docs/tick-accounting-design.md`
both treat Monad's CCTP availability as unverified. It is verified, and
`CctpV2Adapter` needs no change for either chain. Solana uses
`CctpSolanaAdapter` against Circle's Solana programs, whose mainnet bytecode
hashes are recorded in `specs/solana-kamino-crosschain/verification.md`.

## Venue depth, measured

Aave V3 reserve state read from each chain's Pool, configuration decoded with
the Aave V3 bitmap (ACTIVE bit 56, FROZEN bit 57 — not bits 0 and 1):

| Chain | Asset | ACTIVE | FROZEN | aToken | Market size | Supply rate |
|---|---|---|---|---|---|---|
| Ethereum | USDC `0xA0b86991…` | 1 | 0 | `0x98C23E9d…16F5c` | 4,157,637,888 USDC | 2.51% |
| Monad | USDC `0x754704Bc…` | 1 | 0 | `0x35a73BAc…6042` | 86,352,043 USDC | 4.09% |
| Plasma | USDC `0x2d661C89…` | — | — | `0x0` | **not listed** | — |
| Plasma | USDT0 `0xB8CE59FC…` | 1 | 0 | `0x5D72a9d9…0948` | 469,863,543 USDT0 | 2.72% |

Fluid fUSDC, from Instadapp's `fluid-contracts-public` deployment records and
then verified on-chain. Two independent cross-checks establish that source: its
Base and Ethereum fUSDC addresses equal the values this repository already runs.

| Chain | fUSDC | `asset()` | Liquidity layer | `totalAssets` |
|---|---|---|---|---|
| Base | `0xf42f5795…9169` | Base USDC | `0x52Aa8994…e497` | 5,815,578 USDC |
| Ethereum | `0x9Fb7b447…1B33` | `0xA0b86991…` | `0x52Aa8994…e497` | 144,785,421 USDC |
| Arbitrum | `0x1A996cb5…6096` | `0xaf88d065…` | `0x52Aa8994…e497` | 59,468,106 USDC |
| Plasma | `0xCd9C2872…6E81` | `0x2d661C89…` | `0x52Aa8994…e497` | **0.017 USDC** |

Fluid publishes no Monad deployment. Its Liquidity layer sits at the same
address on every chain it serves; `rebalancer` is `0x264786EF…ce92` on Base,
Ethereum and Arbitrum but `0x0` on Plasma.

Morpho Vault V2, from `utils/constants.ts` and then verified on-chain:

| Chain | V2 vault | Evidence |
|---|---|---|
| Base | `0x050cE30b…56f0` | live in production; 21808 bytes; Gauntlet USDC Prime; curator `0x9E33faAE…0585`; 284,480,245 USDC |
| Ethereum | `0x8c106EED…A3D0` | 21808 bytes, identical to Base; asset is Ethereum USDC; `accrueInterestView` and `adaptersLength` both answer; same Gauntlet curator; 103,247,937 USDC |
| Arbitrum | none | `chainConfigs[42161].morphoVaults` lists three V1 vaults and no `version: 2` entry |
| Plasma, Monad | none | `morphoVaults: []` for both |

`GauntletV2EthereumForkTest` already existed in `test/forking/` against
`0x8c106EED…A3D0`, so the Ethereum V2 vault was fork-tested before it was
wired into the registry.

Morpho Blue is not at a single address across chains. It is
`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` on Base and Ethereum but
`0x6c247b1F6182318877311737BaC0844bAa518F5e` on Arbitrum, which is where the
live Gauntlet MetaMorpho vaults point through their `MORPHO()` getter. An empty
read at the canonical address therefore proves nothing; read `MORPHO()` off a
live vault instead.

## Provider reusability

`AaveV3Provider` holds one immutable, the PoolAddressesProvider, and takes the
vault as an argument on every method. It carries no vault binding, so a
cross-chain Strategy reuses the standalone vault's deployed instance exactly as
Base and Arbitrum already do. Verified: the Ethereum instance
`0x107DA8Bd…6941` answers `getIdentifier() == "Aave_V3_Provider"` and
`getSource() == 0x87870Bca…A4E2`, its Pool; the Monad instance
`0xAeEcf7F7…24e0` resolves Pool `0x69a5F9AD…2fef`; the Plasma instance
`0x27a1c09e…28B5` resolves Pool `0x925a2A72…e12`.

`FluidProvider` and `MorphoV2Provider` are deployed fresh per strategy and
validate their source in the constructor, so they need no reuse analysis.

## Defects found

1. The monitoring service was not redeployed after the `Morpho_V2_Provider`
   mapping fix, per the Base upgrade report, so a running monitor values the
   live Base V2 position with V1.1 curator math. MorphoV2 is registered and
   capped on the Base hub now, so this is a live valuation error, not a stale
   note.
2. Phase 4 verification stands at 68 of 71. The three open items are the
   `route base->arbitrum` parameters, the absent `deployments/mainnet/crosschain.json`,
   and the TickAccountant chain set being narrower than the registry.
3. `registry.ts` on the stale `feat/solana-kamino-crosschain` branch lacks the
   Base `fluidFToken` and `morphoV2Vault` entries that have been live since
   2026-11-15. Working from `main` avoids this.
4. Governance on the stand remains one EOA, `0xafA9ed53…8F9D`, holding
   ProxyAdmin, Timelock ownership, ADMIN_ROLE, EXECUTOR and treasury.

## A collision that is not a defect

`deployments/plasma/ProviderManager.json` and
`deployments/monad/USDCRebalancerProxy.json` record the same address,
`0x40F1fBf6a92155a6D321c09936234BFEb9Ec4760`. Both are correct.

A CREATE address is `keccak256(rlp([deployer, nonce]))[12:]` and does not
include the chain id, so one EOA deploying its sixth contract on two chains
lands on the same address twice. Deriving the deployer's nonce sequence
confirms it. From `0xafA9ed53…8F9D`:

| Nonce | Monad | Plasma |
|---|---|---|
| 0 | ProviderManager `0x0c5cEd80…96b5` | |
| 1 | AaveV3Provider `0xAeEcf7F7…24e0` | |
| 2 | Timelock `0x30dC35B7…8EF9` | |
| 3 | USDCRebalancerImplementation `0x44eC9D49…3d60` | |
| 5 | USDCRebalancerProxy `0x40F1fBf6…4760` | ProviderManager `0x40F1fBf6…4760` |
| 6 | | AaveV3Provider `0x27a1c09e…28B5` |
| 7 | | Timelock `0xE1Cfb1BD…B65C` |
| 8 | | USDCRebalancerImplementation `0x4382190F…2aD5` |
| 10 | | USDCRebalancerProxy `0x2Ed9B7fB…3C99` |

Read on Plasma, `0x40F1fBf6…4760` carries 2844 bytes and `owner()` returns the
deployer, so it is a live ProviderManager there; `getYieldToken` returns zero
for every pair, which is what an Aave-only chain with empty `cometPairs`
leaves behind. On Monad the same address is the vault proxy.

The nonce gaps, 4 on Monad and 9 on Plasma, are transactions that did not
create a contract at a scanned address, and `deploy/deploy-usdc-vault.ts`
deploys ProviderManager immediately before AaveV3Provider with nothing between
them when `cometPairs` is empty, which is why nonce and nonce+1 match on Monad.

The operational consequence is real even though nothing is corrupt: any tooling
that reads `deployments/<net>/ProviderManager.json` must resolve it against the
right RPC. `scripts/post-deploy-handover.ts` does, but an address alone carries
no chain identity, so a cross-chain mix-up here would fail silently rather than
loudly.


## Open decisions

- **Plasma asset.** CCTP delivers USDC and native USDC exists on Plasma
  (`0x2d661C89…`, 2.43M total supply), but Aave V3 there lists no USDC, and the
  only USDC venue found is Fluid fUSDC with 0.017 USDC in it. Meanwhile the
  Aave USDT0 market holds 469,863,543 USDT0 and total USDT0 supply on Plasma is
  roughly 998M against 2.43M of USDC. Keeping a Plasma spoke in USDC avoids FX
  risk but has no depth today; converting to USDT0 reaches real depth but needs
  a reviewed swap venue, an FX rule and slippage limits in NAV, which
  `TickAccountant` does not currently price.
- **Ethereum AaveV3 cap.** Set to 0, uncapped, matching how AaveV3 is capped on
  Base and Arbitrum. On those two it is the entry provider, where uncapped is
  structural; on Ethereum the entry is Steakhouse, so this is the one cap on
  that spoke which is a risk choice rather than a requirement.
- **Ethereum gen1.** `0x839E57…7383` runs five Morpho venues no cross-chain
  registry names and holds third-party shares. Treat as a previous generation
  unless a decision says otherwise.
- **Arbitrum Morpho V2.** No V2 source is published for Arbitrum, so
  `morphoV2Vault` stays unset there rather than pointing at a V1 vault, which
  the `MorphoV2Provider` constructor gates would reject.
