# Thesauros cross-chain ops

Off-chain services for the cross-chain vault:

| Script | Service |
|---|---|
| `npm run nav` | NAV updater: builds the snapshot across chains, commits Ticks |
| `npm run keeper` | Epoch keeper: close, clear, fund, (optionally) claim and recall |
| `npm run relayer` | CCTP relayer: delivers transfers with Circle attestations |
| `npm run monitor` | Monitor: checks, Telegram alerts, `/health`, `/metrics`, Tick re-derivation |
| `npm run indexer` | Indexer + read API for the frontend (requests, epochs, NAV history, allocation) |
| `npm run verify-tick -- <ids>` | Independent Tick verification for partners |
| `npm run exec -- <command>` | Operator CLI: status, transfers, capital moves, user and keeper actions. Every write is simulated; nothing is sent without `--yes` |

## Operator CLI

```bash
npm run exec -- status                       # ticks, breakers, vault, epoch, agents, routes, gas
npm run exec -- transfers                    # every CCTP transfer and whether it was delivered
npm run exec -- push 60 --yes                # vault -> hub agent (buffer enforced)
npm run exec -- allocate base 20 --yes       # hub agent -> hub strategy
npm run exec -- bridge base arbitrum all --yes
npm run exec -- allocate arbitrum all --yes  # after the relayer delivered
npm run exec -- deallocate arbitrum 10 --yes
npm run exec -- bridge arbitrum base 10 --yes
npm run exec -- return all --yes             # hub agent -> vault, funds redemptions
npm run exec -- deposit 10 --yes             # as USER_PRIVATE_KEY (falls back to the executor key)
npm run exec -- close --yes | clear --yes | fund --yes
```

Run `npm run exec -- help` for the full list. A revert is decoded to the
contract's custom error when `artifacts/` exists (`npx hardhat compile`).

## RPC limits

Log scans fetch every event of a contract in one `eth_getLogs` per range and
shrink the range to whatever limit the provider reports (Moralis: 100 blocks),
so `LOG_RANGE` is only a starting value. Long-running services scan
incrementally; nothing re-reads history on every pass.

**Production runs only on the server, in Docker: `docs/crosschain-server.md`.**
`npm run preflight -- --layout operators|separate` checks an environment before start.

Configuration, deployment and operations: `docs/crosschain-deployment.md`.
Snapshot rules: `docs/nav-reproduction.md`.
Open items: `docs/crosschain-open-items.md`.

## State files

Both are caches, safe to delete, and must NOT be shared between deployments — the
rehearsal points them into its throwaway directory for exactly that reason.

| Env var | Default | What it holds |
|---|---|---|
| `TRANSFER_INDEX_FILE` | `./crosschain-transfer-index.json` | `BridgeOut` / `BridgeIn` index plus per-chain scan progress, shared by `nav`, `monitor`, `relayer` and `verify-tick` |
| `INDEXER_DB` | `./crosschain-indexer.sqlite` | Indexer's read-model cache for the API |

`TRANSFER_INDEX_FILE` must be on **persistent disk** in production. Without it every
restart of the NAV service re-scans all bridge history from each manifest's
`startBlock`, sequentially; the commit window is a fixed 256 blocks (about 490 s of
usable budget on Base once the reference block sits 10 confirmations deep), so a
cold start that outgrows that budget makes every commit revert
`InvalidHubReference`, Ticks stop, and settlement and instant exits stop with them.
The file is written atomically, is bound to a fingerprint of the deployed
`ChainAgent` addresses so fork or stand state can never be loaded by production,
and rewinds `INDEX_REWIND_BLOCKS` (default 5000) on load as reorg insurance.

Tests: `npm test` (unit tests + ABI drift guard; run `npx hardhat compile` in the
repo root first). The full rehearsal on local forks is `ops/rehearsal/run.sh`.
# RPC rate budget

All read providers in one process share `RPC_REQUESTS_PER_SECOND` (default 10)
and `RPC_COMPUTE_UNITS_PER_SECOND` (default 24). Compose assigns operators
40 CU/s and monitor 12 CU/s. The systemd indexer uses 24 CU/s, leaving headroom
for the allocator and CLI on a 100 CU/s node. Each retry uses the same budgets.
Read requests time out after 15 seconds; ethers' hidden 429 retries are disabled.

Moralis charges `eth_getLogs` and archive calls at 12 CU, versus 3 CU for most
live reads. The weighted limiter lets live reads proceed faster without letting
history scans consume the full node budget. Adjust the combined budgets for the
actual plan and other clients; these are per-process limits, not a shared quota.
See https://docs.moralis.com/rpc-nodes/pricing for current RPC weights.

Only explicit log-range/result-size limits reduce scan ranges. Throttling never
shrinks them. Completed scan batches survive later request failures, and NAV
catches up its transfer index before choosing its short-lived reference block.
