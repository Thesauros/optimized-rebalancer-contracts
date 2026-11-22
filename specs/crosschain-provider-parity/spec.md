---
title: Cross-chain provider parity with the standalone vaults
date: 2026-11-22
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Change: crosschain-provider-parity

Bring the cross-chain vault to full provider parity with the standalone
production vaults, across Base, Arbitrum, Ethereum, Monad, Plasma and Solana.

The cross-chain stand is the core product. Today `TickAccountant.chainIds()`
returns only `[8453, 42161]`: the hub on Base and one spoke on Arbitrum. The
standalone vaults on those chains plus Ethereum, Monad and Plasma hold provider
sets the cross-chain implementation does not fully expose, and Solana exists in
source only. This change closes the gap network by network.

The audit that scopes it is `changes/crosschain-provider-parity/research.md`.
Every address named there was read on-chain on 2026-11-22; nothing is carried
over from documentation alone.

## Required behavior

1. A network's cross-chain strategy exposes at least the providers its
   standalone vault runs, at their deployed addresses where those are reusable.
2. A provider is only added once its venue is verified on that chain: the
   contract has code, its `getSource` resolves to the intended market, its
   `getDepositRate` is readable and positive, and its `asset` equals the spoke's
   USDC. An address that cannot be verified is not added.
3. Provider order follows `strategyProviders`: entry first, fresh Compound
   second, the remaining reused providers, then fresh Fluid, then fresh Morpho
   Vault V2. The entry provider stays uncapped.
4. Adding a provider to an already-initialized strategy is a Timelock
   `setProviders` plus `setProviderCap` sequence, never an in-place mutation.
5. A spoke is only routable once it is in the hub accountant's chain set and
   both directions carry route limits.
6. No deployment record, registry entry or manifest may carry an address that
   was not read back from the chain it belongs to.

## Scope of this change

Stage 1, implemented here:

- Ethereum: add the standalone vault's `AaveV3Provider` and a Morpho Vault V2
  source (Gauntlet USDC Prime) to the `mainnet` registry entry.
- Arbitrum: add the official Fluid fUSDC to the `arbitrum` registry entry.
- Fork coverage for both, and ops tests pinning the new registry state.

Later stages, specified but not implemented here: deploy the Ethereum spoke,
add Monad and Plasma as spokes, deploy and activate the Solana spoke, and
register Fluid on the live Arbitrum strategy through its Timelock.

## Acceptance

- `deploy/crosschain/registry.ts` names, for Ethereum, the standalone vault's
  AaveV3Provider and a V2 vault equal to `chainConfigs[1]`'s version-2 entry;
  for Arbitrum, the official fUSDC.
- Fork test on Ethereum: the seven-provider strategy built exactly as phase 1
  builds it wires every provider, pins every source, keeps the entry provider
  uncapped, enforces each cap, spreads a deposit across all seven and exits
  fully with NAV preserved.
- Fork test on Arbitrum: Fluid wiring, constructor rejection of a non-fToken,
  actions only through the vault, the reported rate equal to the observed
  accrual of the Arbitrum Liquidity supply exchange price, deposit accrual and
  full exit, and rebalancing between Fluid and Aave keeping NAV.
- `npm run test:deploy` green, `ops` suite green including `ops typecheck`,
  `forge test --no-match-path 'test/forking/*'` green.

## Out of scope

Any live transaction: deploying the Ethereum, Monad, Plasma or Solana spoke,
registering Fluid on the live Arbitrum strategy, changing caps on a deployed
strategy, and rotating governance off the single deployer EOA. Those are
governance actions requiring separate authorization. Also out of scope: the
Ethereum gen1 vault's five extra Morpho venues, which belong to a previous
generation and hold third-party shares, and Tron, which is a separate
connector track.
