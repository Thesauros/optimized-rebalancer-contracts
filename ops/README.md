# Thesauros cross-chain ops

Off-chain services for the cross-chain vault:

| Script | Service |
|---|---|
| `npm run nav` | NAV updater: builds the snapshot across chains, commits Ticks |
| `npm run keeper` | Epoch keeper: close, clear, fund, (optionally) claim and recall |
| `npm run relayer` | CCTP relayer: delivers transfers with Circle attestations |
| `npm run monitor` | Monitor: checks, Telegram alerts, `/health`, `/metrics`, Tick re-derivation |
| `npm run verify-tick -- <ids>` | Independent Tick verification for partners |

Configuration, deployment and operations: `docs/crosschain-deployment.md`.
Snapshot rules: `docs/nav-reproduction.md`.
Open items: `docs/crosschain-open-items.md`.

Tests: `npm test` (unit tests + ABI drift guard; run `npx hardhat compile` in the
repo root first). The full rehearsal on local forks is `ops/rehearsal/run.sh`.
