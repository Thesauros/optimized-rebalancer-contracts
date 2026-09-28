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
