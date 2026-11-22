---
title: Cross-chain provider parity verification
date: 2026-11-22
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Verification: crosschain-provider-parity

All results below are from runs on this branch on 2026-11-22. No live
transaction was sent by any of them; every on-chain interaction was a read or a
local fork.

## Automated suites

| Suite | Command | Result |
|---|---|---|
| ops | `cd ops && npm test` | 105 passed, 0 failed, 0 skipped |
| ops types | `cd ops && npm run typecheck` | clean |
| deploy simulation | `npm run test:deploy` | 34 passed, 0 failed |
| Solidity, non-forking | `forge test --no-match-path 'test/forking/*'` | 199 passed, 0 failed, 14 suites |

The ops suite ran 96 passed / 7 skipped before `main` was fast-forwarded to
`62890c0`, and 104 with none skipped after, so merging the executed Base records
unblocked seven tests that had been skipping. The Monad registry assertions take
it to 105.

## Fork suites, against live chain state

| Suite | Chain | Result |
|---|---|---|
| `CrossChainStrategyEthereumForkTest` | Ethereum, floating | 4 passed |
| `FluidProviderEthereumForkTest` | Ethereum, floating | passed |
| `FluidProviderArbitrumForkTest` | Arbitrum, floating | 6 passed |
| `GauntletV2*ForkTest` | Base and Ethereum | passed |
| `BaseStrategyExpansionForkTest` | Base, pinned 55_863_000 | 6 passed |
| `ArbitrumStrategyExpansionForkTest` | Arbitrum, floating | 5 passed |
| `CrossChainStrategyMonadForkTest` | Monad, pinned 124_400_000 | 4 passed |

The three Ethereum and Arbitrum files together reported 24 passed in one run.
`BaseStrategyExpansionForkTest` was re-run after the merge to confirm it is
unaffected: it replays a pinned pre-upgrade block, so the executed Base upgrade
does not invalidate it.

`CrossChainStrategyMonadForkTest` needs a distinct invocation because forge
1.10.0 will not create a Monad fork inside an Ethereum EVM:

```sh
MONAD_RPC_URL=https://rpc.monad.xyz \
  forge test --rpc-url https://rpc.monad.xyz --fork-block-number 124400000 \
  --match-contract CrossChainStrategyMonadForkTest
```

Without `MONAD_RPC_URL` the file reports one skipped test rather than passing
vacuously. That distinction was checked both ways: the run that reported
`4 passed` in 737 microseconds at 2371 gas was the early-return idiom skipping
every body, and switching to `vm.skip` is what exposed it.

## What the fork tests actually establish

`CrossChainStrategyEthereumForkTest` builds the seven-provider strategy exactly
as `01-deploy.ts` builds it from the registry, then proves every pinned source,
that the entry provider stays uncapped, that each of the three numeric caps
rejects an oversized allocation, that a deposit spreads across all seven and
that a full exit returns principal with NAV preserved.

`FluidProviderArbitrumForkTest` proves the load-bearing per-chain property:
`testRateIsTheAccrualOfTheSupplyExchangePrice` skips 30 days on the fork and
asserts the rate `FluidProvider` reports equals the observed accrual of the
Arbitrum Liquidity layer's supply exchange price. `FluidProvider` reads that
price out of storage, so a chain whose Fluid deployment differed in layout would
misprice yield silently rather than revert. Base and Ethereum already prove
their own layouts.

`ArbitrumStrategyExpansionForkTest` replays the live spoke: asserts it still
runs the pre-upgrade implementation, upgrades it atomically and checks that all
ten ERC7201 storage words the migration does not deliberately reset are
byte-identical, along with totalSupply, totalAssets, both share balances, every
legacy position and every legacy cap; then registers six providers through the
spoke Timelock at its 24h delay, confirms the `Timelock__StillLocked` revert
before the ETA, round-trips USDC through Fluid, and confirms the 3000 bps cap
rejects a 40% allocation atomically.

`CrossChainStrategyMonadForkTest` proves the property that makes provider reuse
safe, against live Monad state rather than from source: after a 10,000 USDC
deposit to the new spoke, the standalone vault's `getDepositBalance`, its aToken
balance and its `totalAssets` are all unchanged, and still unchanged after the
spoke exits.

## On-chain reads used as evidence

Every address placed in `deploy/crosschain/registry.ts` was read back from the
chain it belongs to before being written down.

| Claim | Method | Result |
|---|---|---|
| CCTP V2 live on Monad and Plasma | `getCode` at both hardcoded addresses on five chains | identical runtime, keccak `0xd2c8d48075d832fb7d07…`, 2175 bytes |
| CCTP domains | `MessageTransmitter.localDomain()` | Base 6, Arbitrum 3, Ethereum 0, Monad 15, Plasma 33 |
| Ethereum AaveV3 reusable | `getIdentifier()`, `getSource()` | `Aave_V3_Provider`, resolves Pool `0x87870Bca…A4E2` |
| Ethereum Aave USDC depth | `getReserveData`, aToken `totalSupply()` | ACTIVE, not frozen, 4,157,637,888 USDC |
| Monad Aave USDC depth | same | ACTIVE, not frozen, 86,352,043 USDC |
| Plasma Aave USDC | `getReserveData(USDC)` | `configuration = 0`, `aToken = 0x0` |
| Plasma Aave USDT0 depth | `getATokenTotalSupply`, aToken `balanceOf` | 468,084,694 supplied, 109,000,056 withdrawable |
| Ethereum Morpho V2 interface | `accrueInterestView()`, `adaptersLength()`, `maxRate()`, `performanceFee()` | all answer; 21808 bytes, identical to Base |
| Gauntlet curator discriminator | `curator()` on Base, Ethereum and the reported decoy | `0x9E33faAE…0585`, `0x9E33faAE…0585`, `0x1b0448bf…64f4` |
| Fluid fUSDC per chain | `asset()`, `getData()`, `totalAssets()`, `minDeposit()` | Arbitrum 59,468,106; Plasma 0.017 |
| Plasma USDC exit ceiling | `USDC.balanceOf(pool)` | 30,215.64 USDC, against 2,371,265.76 USDT0 |
| Spoke implementations | EIP-1967 implementation slot plus `getHighWaterMark()` | Base `0x6909E365…` answers; Arbitrum `0x84163d2d…` reverts |
| Hub chain set | `TickAccountant.chainIds()` | `[8453, 42161]` |

The Morpho V2 vault address for Ethereum came from `utils/constants.ts` and from
`deployments/plans/gauntlet-v2-2026-10-25/mainnet.json`, and was then confirmed
on-chain; `GauntletV2EthereumForkTest` already existed against it. The Fluid
addresses came from Instadapp's `fluid-contracts-public` deployment records, a
source cross-validated by its Base and Ethereum entries equalling the values
this repository already runs.

## Two claims retracted during the work

`deployments/plasma/ProviderManager.json` was first reported as corrupt because
it records the same address as the Monad vault proxy. It is correct: a CREATE
address is `keccak256(rlp([deployer, nonce]))[12:]` and carries no chain id, and
deriving the deployer's nonce sequence shows nonce 5 is the Plasma
ProviderManager and the Monad vault proxy. The original error was reading a
revert from vault-shaped methods as an absent account. Commit `69415f1`.

Arbitrum was first reported as having no Morpho Vault V2. One exists at
`0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78`, interface-identical to Base's
under the same curator. It is not registered because it holds 191,941 USDC with
its underlying markets near 91% utilisation. The registry test comment was
corrected rather than left claiming no source exists.

## Not verified, and why

- **Phase 4 against live Base.** `identities()` requires `CROSSCHAIN_SAFE`,
  `CROSSCHAIN_NAV_UPDATER`, `CROSSCHAIN_EXECUTOR` and `CROSSCHAIN_GUARDIAN`; none
  is present in the local `.env`. Supplying invented values would have made the
  Safe-ownership checks meaningless, so the two new checks were validated by
  calling `curator()` and `asset()` directly on the live vaults, which is the
  same pair of reads `checkDeployment` performs, plus a fixture-level negative
  test. Phase 4 also still reports the pre-existing failures: the
  `route base->arbitrum` parameters, the absent
  `deployments/mainnet/crosschain.json`, and the accountant chain set.
- **CCTP token-pair mapping and `maxFee` for Base to Monad.** Every `maxFee`
  signature tried reverted on the known-good Base to Arbitrum control as well, so
  the failures were wrong selectors rather than missing configuration. What is
  established is one level up: `remoteTokenMessengers` is populated in both
  directions, one TokenMinter `0xfd78EE919681417d192449715b2594ab58f5D002` serves
  all five chains, and that minter is an authorized `isMinter` of each chain's
  USDC. Per-token burn limits and fee curves are unverified, so `maxFeeBps` for
  a Monad route is inherited from the profile rather than derived from a
  measured fee.
- **Monad reorg depth.** `confirmations: 20` is chosen to match Arbitrum's
  wall-clock depth at Monad's measured 0.307 s block time. It is the closest
  analogue, not a measurement, and the registry comment says so.
- **The Plasma DEX venue's provenance.** Its factory speaks the canonical
  Uniswap V3 ABI and its position manager names itself "Uniswap V3 Positions
  NFT-V1", but the canonical Uniswap addresses are empty on Plasma and a
  bytecode-identity cross-check against Base could not be completed. Treat it as
  an unaudited third-party venue. Plasma is deferred, so nothing depends on it.
- **Solana.** Not built and not deployed in this change, so no `programDataSha256`
  and no manifest exist. Circle's two mainnet program IDs are recorded in
  `specs/solana-kamino-crosschain/verification.md` against mainnet bytecode but
  are not repository artifacts; `CCTP_MAINNET_DUMP=true` has not been re-run.
- **Drift.** Plasma pool balances moved between two readings hours apart, and
  the Ethereum Morpho V2 vault went from 106.96M at block 26270036 to 103.25M.
  Every depth figure here is a snapshot and decays.
