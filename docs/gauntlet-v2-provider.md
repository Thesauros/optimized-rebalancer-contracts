# Gauntlet Morpho V2 provider

`MorphoV2Provider` implements the existing `IProvider` interface for Morpho Vault
V2. `MorphoProvider` continues to handle MetaMorpho V1 positions. A V2 provider
has a single immutable source vault; its identifier is `Morpho_V2_Provider`.

| Chain | Strategy | Morpho V2 source | Deployment record |
| --- | --- | --- | --- |
| Ethereum | Gauntlet USDC Prime V2 | `0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0` | `GauntletPrimeV2MorphoProvider` |
| Base | Gauntlet USDC Prime V2 | `0x050cE30b927Da55177A4914EC73480238BAD56f0` | `GauntletPrimeV2MorphoProvider` |

Addresses are confirmed by the [Ethereum vault](https://app.morpho.org/ethereum/vault/0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0/gauntlet-usdc-prime),
[Base vault](https://app.morpho.org/base/vault/0x050cE30b927Da55177A4914EC73480238BAD56f0/gauntlet-usdc-prime)
and fork lifecycle tests. Both use native USDC on their respective chains.
No V2 source is configured for Arbitrum, Plasma or Monad.

## Accounting and execution

- Actions run through `delegatecall` in the Rebalancer; receipt shares belong to
  that Rebalancer. The provider rejects a different context or underlying asset.
- Balance is `previewRedeem(balanceOf(owner))`, including pending V2 performance
  and management fees, virtual shares, capped accrual and recognized losses. This
  reports the full position, including assets temporarily unavailable for withdrawal.
- Native `deposit`/`withdraw` perform cap, gate and liquidity checks. V2's `max*`
  views always return zero, so the provider does not use them. A failed withdrawal
  propagates to Rebalancer's existing fallback logic. Forced deallocation and its
  penalties are not performed automatically.
- `getDepositRate` estimates net APR in ray (`1e27`), excluding external rewards.
  It weights Morpho market APRs by allocations, deducts underlying V1/market fees,
  includes idle dilution, caps gross APR at V2 `maxRate * 365 days`, deducts the V2
  performance fee, then subtracts the annualized **per-second** management fee.
  Negative estimates floor to zero. Configured fees are deducted conservatively
  even if a fee recipient is temporarily gated.
- Rate look-through covers `MorphoVaultV1Adapter` and `MorphoMarketV1AdapterV2`.
  Other adapter families contribute zero estimated yield while their assets remain
  in the denominator. Each adapter's full weighted rate calculation runs through
  an external view call with a 3,000,000 gas allowance; unsupported ABI, malformed
  metadata, reverts or exhausted gas contribute zero estimated yield. Native V2
  valuation failures still propagate to Rebalancer's provider health checks.

See [Morpho's integration guide](https://docs.morpho.org/developers/earn/tutorials/assets-flow/)
and the [Vault V2 source](https://github.com/morpho-org/vault-v2/blob/main/src/VaultV2.sol).

## Deployment and activation

New full-vault deployments select `MorphoV2Provider` for configuration entries
with `version: 2`; entries without a version retain `MorphoProvider`.

To deploy only the additional provider for an existing vault:

```sh
npx hardhat deploy --deploy-scripts deploy/providers --tags gauntlet-v2-provider --network base
# or --network mainnet
```

This deploys/verifies a provider; it does not register it or move existing funds.
`DRY_RUN=1` is accepted only with the in-process `--network hardhat` network;
other networks are rejected before RPC or signer access, including networks named
`localhost` or `baseLocal`. This guard applies to both deployment scripts. To
rehearse, use a local Hardhat fork with `FORK_CHAIN_ID` identifying the source chain.
The explicit script directory avoids loading the repository's independent
cross-chain operational scripts. With recent Foundry versions, use
`FOUNDRY_AUTO_DETECT_REMAPPINGS=false` if hardhat-foundry rejects automatically
discovered context remappings; the checked-in `remappings.txt` remains sufficient.
The full `usdc-vault` deployment path is intended for new vaults and does not
automatically add a new provider to an existing initialized proxy.

Before activation, governance must verify chain, source asset, gates (the
Rebalancer must be allowed), current adapters, caps, liquidity and valuation gas.
Append the new provider to the existing list through timelocked `setProviders`;
retain every provider with a live balance. Then an authorized executor can use
`rebalance` to move assets from V1 to V2. Entry selection uses `setEntryProvider`.
Keep the V1 provider registered until its position is empty. For rollback, select
the previous entry provider and rebalance out before removing the V2 provider.

## Validation

```sh
forge test --match-path test/unit/MorphoV2Provider.t.sol -vv
forge test --match-path test/forking/GauntletV2MorphoProvider.t.sol -vv
forge test --no-match-path 'test/forking/**'
npm run test:deploy
```

The fork tests require `BASE_RPC_URL` and `ETHEREUM_RPC_URL`. They cover native
zero max views, deposit/withdraw/redeem, rate reads, fee-aware position valuation,
provider health and V1/V2 rebalances on both chains. Unit tests exercise fee
dilution, losses, unknown adapters, APR units and fee composition, failed sources,
asset/context checks, and fuzzed rounding.
