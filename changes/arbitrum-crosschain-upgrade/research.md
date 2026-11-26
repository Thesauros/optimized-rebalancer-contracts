# Arbitrum venue research — 2026-11-22

This is read-only source and on-chain research for `arbitrum-crosschain-upgrade`.
It is not a deployment record, cap approval, allocation instruction or financial
readiness verdict. No candidate provider address or historical HWM is invented.

## Primary sources

- [Official Morpho Gauntlet USDC Prime V2 page](https://app.morpho.org/arbitrum/vault/0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78/gauntlet-usdc-prime).
- [Official Morpho V2 discovery API, Arbitrum native USDC filter](https://api.morpho.org/v0/vaults-v2?chain_ids=42161&asset_addresses=0xaf88d065e77c8cC2239327C5EDb3A432268e5831&limit=100).
- [Official Morpho V2 state API for Prime](https://api.morpho.org/v1/vaults-v2/42161:0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78/state).
- [Official Morpho V2 allocation API for Prime](https://api.morpho.org/v0/vaults-v2/42161:0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78/allocations).
- [Morpho API documentation](https://docs.morpho.org/api/) and [Vault V2 contract source](https://github.com/morpho-org/vault-v2/blob/main/src/VaultV2.sol).
- [Official Fluid Arbitrum fUSDC deployment JSON, pinned source commit](https://github.com/Instadapp/fluid-contracts-public/blob/404d73f91e6806f881f8dabeb30494f93f9e99b7/deployments/arbitrum/fToken_fUSDC.json).
- [Official Fluid Arbitrum LiquidityResolver deployment/ABI](https://github.com/Instadapp/fluid-contracts-public/blob/main/deployments/arbitrum/LiquidityResolver.json).

Morpho discovery identifies Prime as version `2.0`, not a V1 vault with a similar
name. The discovery endpoints are mutable live data; the dated observations below
are not claims that those endpoints will retain the same values.

## Pinned on-chain observations

Arbitrum block **526524948**, timestamp **1795353442**,
**2026-11-22 13:17:22 UTC**. All asset addresses below were read on-chain using
read-only RPC; authenticated RPC URLs and credentials are intentionally absent.

Native USDC: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, six asset decimals.
Current Strategy: `0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71`.

### Gauntlet USDC Prime V2

- Source: `0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78`.
- `asset()` equals native Arbitrum USDC; `name()` is `Gauntlet USDC Prime`,
  `symbol()` is `gtusdcp`; share decimals are **18**.
- Source runtime hash:
  `0x551fe10f4b3a42c410cea72f46a237c0c403a4c698e3af675136bc6bdfcda382`.
- `totalAssets()` and the accrued asset value were `191940890831` USDC units,
  or `191940.890831 USDC`. `previewDeposit(1000000)` returned
  `970761063970369946` share units. This is not a six-decimal share amount.
- `accrueInterestView()` and `adaptersLength()` succeeded. Its one configured
  adapter/liquidity adapter was `0xDe786636614D28e1D831df51C33f19C4c450E898`.
  The adapter exposes the current provider's supported MorphoMarketV1AdapterV2
  interface: `morpho()`, `marketIdsLength()`, `marketIds()` and
  `expectedSupplyAssets()`. It tracks four markets; its Morpho Blue address is
  `0x6c247b1F6182318877311737BaC0844bAa518F5e`.
- Management/performance fees were zero. All four share/asset gate addresses
  were zero. These are observations, not permanent properties.
- `maxDeposit` and `maxWithdraw` returned zero as expected for native Vault V2;
  zero here does not establish available liquidity or prohibit normal deposits.
- The official state API near this block (indexed block 526524853) reported
  `191940.882286 USDC` assets and `138347.074883 USDC` withdrawable. This is an
  API estimate at its own indexing point, not a guaranteed withdrawal quote at
  the pinned block. Borrower utilization, adapter routing and gates can restrict
  normal withdrawals; wait for liquidity rather than force-deallocate.

The interface and source checks support reusing `MorphoV2Provider`. A complete
financial compatibility claim still needs the actual-state fork round trip and
valuation checks. Its provider estimates lending APR from supported adapters,
subtracts vault fees and excludes external rewards; unsupported adapters contribute
zero yield rather than using `maxRate` as a promised return.

Morpho's official discovery also lists Gauntlet USDC Balanced V2 at
`0x55a2B207b0074E13AdCb858950a81B7a04775E0F`, with the same native asset. It was
checked as an alternative, not selected for this release. Do not append both
merely to increase venue count: they have overlapping underlying market exposure.

### Fluid fUSDC

- Source: `0x1A996cb54bb95462040408C06122D45D6Cdb6096`.
- Official constructor arguments identify Liquidity
  `0x52Aa899454998Be5b000Ad077a46Bbe360F4e497`, lending factory
  `0x54B91A0D94cb471F37f949c60F7Fa7935b551D03` and native Arbitrum USDC.
  The recorded deployment transaction is
  `0xc5896065ddfc012ea85e2e34cda18970bc4d66ba872be2cae65811832224af68`.
- On-chain asset and `getData()` agree with those addresses. Name is
  `Fluid USD Coin`, symbol `fUSDC`; share decimals are **6**.
- Source runtime hash:
  `0x9c80b29776890f7adf531de64df342cbb09c99ee5af4b583c0d1c70d2e86291b`.
- `totalAssets()` was `59468087412216` units / `59468087.412216 USDC`;
  `previewDeposit(1000000)` returned `876975` fUSDC share units.
  `minDeposit()` was `2` units, or `0.000002 USDC`.
- Liquidity `readFromStorage` for the USDC exchange-prices mapping at slot 5
  succeeded, as required by the existing `FluidProvider` APR reader. The provider
  excludes separate fToken rewards rather than overstating its base lending rate.
- The official resolver `0xca13A15de31235A37134B4717021C35A3CF25C60`, queried
  through its published ABI for `(fToken, USDC)`, returned supply
  `59468087.412635 USDC`, withdrawable-until-limit `29734043.706318 USDC`, and
  actual withdrawable `8020283.038258 USDC`. The latter equals observed idle USDC
  in Liquidity. The expansion configuration was 5000 bps over 21600 seconds.
  Thus liquidity, not full TVL, bounded the immediate withdrawal at this snapshot.

These reads support the existing `FluidProvider` constructor and data interfaces.
Normal withdrawals remain limited by Liquidity's current cash and withdrawal
limits. A successful ABI read does not replace a deposit/withdraw fork rehearsal.

## Existing Arbitrum positions and preservation

Observed provider order and caps:

| Provider | Adapter address | Source | Cap bps |
| --- | --- | --- | --- |
| Aave V3, entry | `0xA34574Dae6284EDc7348C36A80242b92CFBd13A5` | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | 0 |
| Compound V3 | `0x9eE0a4d3d9f4172FEB7E518EBbd73AF9a5E16664` | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` | 5000 |
| Gauntlet Core Morpho V1 | `0xeB98d46937C537efF376361536D58d78c57c40d7` | `0x7e97fa6893871A2751B5fE961978DCCb2c201E65` | 4000 |
| Steakhouse High Yield Morpho | `0x6240402d3Cb33777D4E5E6B5791bC8518AEb8B99` | `0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA` | 3000 |
| Steakhouse Prime Morpho | `0x0D9FD60E25b0C3b2416D46F7dd311b0ED6743484` | `0x250CF7c82bAc7cB6cf899b6052979d4B5BA1f9ca` | 4000 |

Aave's source is its resolved Pool, not the registry address. Its exact
`getSource(nativeUSDC, Strategy, zeroAddress)` result was also reconfirmed at
block 526525999, 2026-11-22 13:22:55 UTC. Prime V2 is a distinct source from
existing Gauntlet Core V1 and must not replace that position.

## Decisions and remaining evidence

Prepare two **new Arbitrum provider adapter deployments** against the sources
above, plus the reviewed Rebalancer implementation. No actual candidate adapter
address is asserted by this research. Append those verified adapters after the
five current providers and preserve the Aave entry. Proposed ceilings are Fluid
3000 bps and Prime V2 2000 bps, matching the Base release pattern; these remain
explicit reviewed release inputs, not risk-approved allocations.

Historical HWM provenance, fee-waiver acceptance, candidate deployment/runtime
proof, pinned fork results, compatible allocator support, service/image evidence,
fresh complete cross-chain NAV and concrete reviewed execution inputs remain
separate prerequisites. The current allocator lacks Fluid/V2 market readers and
registry support; no service rollout or capital allocation is justified by these
source checks alone. ProviderManager/CCTP replacement and any Base hub upgrade
are separate from this Arbitrum Strategy preparation.
