# Cross-chain vault: what is still needed

State on 2026-09-28, branch `feat/crosschain-tick-epoch`.

**Done:** contracts, deployment phases 1–5 for Base and Arbitrum, and the four
services (NAV updater, keeper, CCTP relayer, monitor), rehearsed end to end on
forks. The items below are **not** done. Each is marked with whether it blocks
the first mainnet deployment.

## A. Backend that is not built

| # | Item | Blocks launch? | Why it is needed | Suggested home |
|---|---|---|---|---|
| A1 | **Cross-chain allocation strategy** (spec for the backend developer: `docs/tz-crosschain-allocator.md`) (the "brain"): decides how much sits on Base vs Arbitrum and in which provider, executes allocate / rebalance / bridgeOut, and plans recalls from spokes to fund redemptions | **Yes, for yield.** No, for safety: without it capital stays in the hub vault buffer and hub strategy | The existing `Thesauros-Rebalance-Engine/apps/rebalancer` drives single-chain `Rebalancer.rebalance`; it does not know `ChainAgent`, CCTP or cross-chain liquidity. The keeper's autofund covers hub-local recalls only | Extend Rebalance-Engine (it already has provider-rate data, Safe SDK and AWS Secrets Manager) with a `crosschain` module calling `ChainAgent` / `EpochVault.pushToAgent` |
| A2 | ~~Indexer + API for the frontend~~ **Done**: `ops/src/indexer.ts` (rehearsed on forks) | — | — | — |
| A3 | ~~Frontend flows~~ **Done**: `thesauros-app` branch `feat/crosschain-vault`, page `/crosschain` (builds; not yet exercised against a live deployment) | — | — | — |
| A4 | **Key management for hot keys** (NAV updater, executor, keeper/relayer) | Yes | Hot keys in `.env` repeat SEC-002 | AWS Secrets Manager / KMS, as the Rebalance-Engine already uses |
| A5 | **Hosting** for the four `ops` services and paid RPCs (a different provider for the monitor than for the NAV updater) | Yes | Liveness: no Ticks means no clearing and no instant exits | Railway, like the existing services |
| A6 | Public snapshot archive (optional): JSON of every Tick for partners | No | The snapshot is already public as calldata; `ops/src/verify-tick.ts` reproduces any Tick | docs site / data service |

## B. Protocol gaps (known and documented)

| # | Item | Blocks launch? | Note |
|---|---|---|---|
| B1 | **External audit** of `TickAccountant`, `EpochVault` + `EpochVaultLogic`, `ChainAgent`, `CctpV2Adapter`, the `Rebalancer` diff, the snapshot spec, and the ops NAV engine | **Yes, before meaningful TVL** | Internal tests: 144 Foundry + 12 ops tests, invariants, negative controls, fork rehearsal |
| B2 | Reward tokens (COMP, Morpho rewards) are neither claimed nor recognized | No | Conservative: they are simply not counted |
| B3 | Deposits on spokes | No | V1 is hub-only; users reach Base via CCTP themselves |
| B4 | Plasma (USDT0) and Monad | No | USDT0 needs an FX rule; CCTP availability on Monad is not verified |
| B5 | `Rebalancer` fee high-water mark | No | Strategy fees are 0; vault fees go through the accountant, which has a HWM |
| B6 | Partial funding of a large epoch | No | A large epoch blocks later small ones until funded; there is room in `EpochVault` for it now |
| B7 | CCTP fast transfers | No | Supported by configuration (`minFinalityThreshold` 1000 plus `maxFeeBps`); defaults to standard |

## C. Decisions and actions for the founder

| # | Item |
|---|---|
| C1 | ~~Timelock delay~~ **Decided: 24 h** |
| C2 | Distinct NAV updater, executor and guardian keys: **after the stand test** (stand uses `0xafA9…8F9D` for everything; rotation with `06-rotate-governance.ts`) |
| C3 | Launch limits: explained with stand and production values in `docs/crosschain-limits.md` |
| C4 | Safe signer availability: **stand uses the deployer EOA**; revisit the Safe threshold before rotation |
| C5 | **Legacy `CrossChainVault` (SEC-018): open, and the key question changed.** The founder reports not having deployed it. On-chain (Blockscout, checked 2026-09-28) the contract `0x8AD87BB0…78a8Ae` was created by `0xafA9ed53…8F9D` (tx `0x7419a4a4…3c0c`), which also granted its roles and ran its operations on 2026-05-04..06. So whoever deployed it used the Thesauros deployer key. That key is in plaintext in `.env` files (SEC-002), and the stand profile gives it every role. Before the stand holds any money: establish who used the key in May 2026, or rotate to a fresh key for the stand |
