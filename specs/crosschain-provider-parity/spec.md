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

Implemented here:

- Ethereum: add the standalone vault's `AaveV3Provider` and a Morpho Vault V2
  source (Gauntlet USDC Prime) to the `mainnet` registry entry.
- Monad: register as an Aave-only spoke, with the hub route in both directions
  and a pinned fork test.
- Arbitrum: the Fluid APR-accrual fork check only. Its registry entry and upgrade
  path belong to `feat/arbitrum-crosschain-upgrade`, which appeared on the remote
  during this work and covers them more thoroughly.
- Phase 4 gains a Morpho V2 `curator()` and `asset()` check, because six decoy
  vaults on Ethereum and Arbitrum copy a genuine Gauntlet name and symbol.
- The aggregate forking suite stops failing on an operator trace that required
  two environment variables and had no skip path.
- Solana: a written activation plan. No keypair generated, nothing built.

Decided against:

- Plasma. Deferred on measured evidence. A USDC spoke could receive funds and
  could not return them: the chain's entire USDC exit capacity is one
  EOA-controlled pool holding about 30k USDC against 2.37M USDT0, and there is
  no USDC yield venue of any kind. A USDT0-denominated spoke would work against
  a 468M USDT0 Aave market but needs an FX rule in NAV that `TickAccountant`
  does not make, which is a product decision.
- Registering Morpho V2 on Arbitrum in this change. The vault exists and is
  interface-identical to Base's under the same curator, but holds 191,941 USDC
  with its underlying markets near 91% utilisation, so this spoke would dominate
  it. That measurement is recorded for the branch that does register it.

Not done here, and needing separate authorization: deploying the Ethereum and
Monad spokes, the Arbitrum upgrade itself, the Solana deployment, and rotating
governance off the single deployer EOA.

## Acceptance

- `deploy/crosschain/registry.ts` names, for Ethereum, the standalone vault's
  AaveV3Provider and a V2 vault equal to `chainConfigs[1]`'s version-2 entry; and
  for Monad, the standalone vault's AaveV3Provider as its only, uncapped entry
  provider, with the hub routing back.
- Fork test on Ethereum: the seven-provider strategy built exactly as phase 1
  builds it wires every provider, pins every source, keeps the entry provider
  uncapped, enforces each cap, spreads a deposit across all seven and exits
  fully with NAV preserved.
- Fork test on Monad: the single-provider strategy wires correctly, and a spoke
  deposit leaves the standalone vault's position, aToken balance and NAV
  unchanged before and after the exit.
- Fork test on Arbitrum: Fluid wiring, constructor rejection of a non-fToken,
  actions only through the vault, the reported rate equal to the observed
  accrual of the Arbitrum Liquidity supply exchange price, deposit accrual and
  full exit, and rebalancing between Fluid and Aave keeping NAV.
- `npm run test:deploy` green, `ops` suite green including `ops typecheck`,
  `forge test --no-match-path 'test/forking/*'` green, and the aggregate
  `forge test --match-path 'test/forking/*'` green with no failures.

## Out of scope

Any live transaction: deploying the Ethereum, Monad, Plasma or Solana spoke, the
Arbitrum upgrade and provider registration, changing caps on a deployed
strategy, and rotating governance off the single deployer EOA. Those are
governance actions requiring separate authorization. Also out of scope: the
Ethereum gen1 vault's five extra Morpho venues, which belong to a previous
generation and hold third-party shares; Tron, which is a separate connector
track; and the `arbitrum` registry entry, owned by
`feat/arbitrum-crosschain-upgrade`.
