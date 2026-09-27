# Cross-chain vault: what is still needed

State on 2026-09-28, branch `feat/crosschain-tick-epoch`.

**Done:** contracts, deployment phases 1–5 for Base and Arbitrum, and the four
services (NAV updater, keeper, CCTP relayer, monitor), rehearsed end to end on
forks. The items below are **not** done. Each is marked with whether it blocks
the first mainnet deployment.

## A. Backend that is not built

| # | Item | Blocks launch? | Why it is needed | Suggested home |
|---|---|---|---|---|
| A1 | **Cross-chain allocation strategy** (the "brain"): decides how much sits on Base vs Arbitrum and in which provider, executes allocate / rebalance / bridgeOut, and plans recalls from spokes to fund redemptions | **Yes, for yield.** No, for safety: without it capital stays in the hub vault buffer and hub strategy | The existing `Thesauros-Rebalance-Engine/apps/rebalancer` drives single-chain `Rebalancer.rebalance`; it does not know `ChainAgent`, CCTP or cross-chain liquidity. The keeper's autofund covers hub-local recalls only | Extend Rebalance-Engine (it already has provider-rate data, Safe SDK and AWS Secrets Manager) with a `crosschain` module calling `ChainAgent` / `EpochVault.pushToAgent` |
| A2 | **Indexer + API for the frontend**: user requests (pending / claimable / claimed), epochs, Tick history, NAV and rate series, in-flight transfers | Yes, for the UI | Every fact is an event (`DepositRequested`, `RedeemRequested`, `DepositsCleared`, `RedeemsCleared`, `EpochFunded`, `TickCommitted`, `BridgeOut`/`BridgeIn`), so an indexer is straightforward, but none exists | `Rebalance-Engine/apps/indexer` + `apps/api`, or `thesauros-vault-data-service` |
| A3 | **Frontend flows**: request deposit, request redeem, claim, instant exit (with the fee and limits shown), epoch countdown, pending state | Yes, for users | The vault is asynchronous (ERC-7540-shaped); an ERC-4626 widget does not fit | landing / app repo |
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
| C1 | Timelock delay (default 24 h in the runbook; the contract minimum is 30 min) |
| C2 | Distinct NAV updater, executor and guardian keys, and who holds the guardian |
| C3 | Launch limits: epoch deposit cap, instant-exit per call and per day, route volume. Registry defaults are placeholders sized for a small launch |
| C4 | Safe signer availability for `ratifyTick` and `unpause` (2-of-2 today: a single unavailable signer stalls recovery from a quarantine) |
| C5 | Pause deposits of the legacy `CrossChainVault` on Base (SEC-018), independent of this deployment |
