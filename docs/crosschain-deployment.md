# Cross-chain vault: deployment and operations runbook

Scope: the first production deployment on **Base (hub)** and **Arbitrum
(spoke)**, the services that run it, and the procedure to add networks.

The whole procedure has been rehearsed end to end on local forks of both
chains: `ops/rehearsal/run.sh`, last run 2026-09-28, result `REHEARSAL PASSED`.
The rehearsal covered:

* phase 4: 56/56 checks on Base and 32/32 on Arbitrum;
* phase 5: an empty governance plan on both;
* a full deposit → tick → epoch → clearing → claim cycle;
* a real CCTP V2 burn on Base, delivered by the relayer on Arbitrum;
* independent re-derivation of a Tick;
* the monitor, with no critical check.

---

## 1. What is deployed

| Contract | Base | Arbitrum | Upgradeable | Owner / admin after handover |
|---|---|---|---|---|
| `Timelock` | ✓ | ✓ | no | Safe |
| `Rebalancer` strategy (proxy, via `VaultFactory`) | ✓ | ✓ | yes | ProxyAdmin → Safe; ADMIN Safe; timelock Timelock |
| `ProviderManager` + `CompoundV3Provider` (fresh, not the EOA-owned live one) | ✓ | ✓ | no | Safe (Ownable2Step, Safe accepts) |
| Aave/Morpho providers | reused | reused | no | stateless, immutable config |
| `ChainAgent` (proxy) | ✓ | ✓ | yes | ProxyAdmin → Safe; ADMIN Safe; timelock Timelock |
| `CctpV2Adapter` | ✓ | ✓ | no | governance Timelock |
| `TickAccountant` (proxy) | ✓ | — | yes | ProxyAdmin → Safe; ADMIN Safe; timelock Timelock |
| `EpochVaultLogic` library + `EpochVault` (proxy) | ✓ | — | yes | ProxyAdmin → Safe; ADMIN Safe; timelock Timelock |

* **Registry.** Addresses and parameters come from `deploy/crosschain/registry.ts`.
* **Manifests.** Results are written to `deployments/<network>/crosschain.json`.
  Commit them: the services read them.
* **Proxy ownership.** Every proxy is created with the Safe as ProxyAdmin owner
  and initialized in the same transaction, so there is no SEC-001 window.

## 1a. Stand profile (test stand with 50–100 USD)

Founder decision (2026-09-28): the first deployment is a test stand where the
Thesauros deployer address `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` holds
governance and every operational role until the stand has been tested.

```bash
export CROSSCHAIN_PROFILE=stand
export CROSSCHAIN_SAFE=0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D
export CROSSCHAIN_NAV_UPDATER=$CROSSCHAIN_SAFE CROSSCHAIN_EXECUTOR=$CROSSCHAIN_SAFE CROSSCHAIN_GUARDIAN=$CROSSCHAIN_SAFE
export CROSSCHAIN_TIMELOCK_DELAY=86400
# services: NAV_UPDATER_PRIVATE_KEY = EXECUTOR_PRIVATE_KEY = KEEPER_PRIVATE_KEY = RELAYER_PRIVATE_KEY = the deployer key
```

What the stand profile changes:

* **Relaxed identity checks.** Phases 1–4 accept an EOA as governance and roles
  that are the deployer itself.
* **Limits.** They are sized for 50–100 USD (`docs/crosschain-limits.md`).
* **Visibility.** The manifest records `profile: stand`, and the monitor keeps a
  permanent warning until rotation.

Leaving it:

1. Run `06-rotate-governance.ts` with `NEW_SAFE`, `NEW_NAV_UPDATER`,
   `NEW_EXECUTOR`, `NEW_GUARDIAN` on both chains.
2. Queue the treasury change on the Timelock (the script prints it).
3. The Safe calls `acceptOwnership` on the Timelock and on the ProviderManager.
4. Run phase 4 with the new identities.
5. Run phase 5 with `CROSSCHAIN_PROFILE=production` to raise the limits through
   the Timelock.

Rehearsed on forks (`REHEARSAL_PROFILE=stand ops/rehearsal/run.sh`), result
`STAND ROTATION PASSED`.

## 2. Prerequisites

### Identities

Use four distinct keys, none of them the deployer:

| Variable | Holds | Used by |
|---|---|---|
| `CROSSCHAIN_SAFE` | Safe multisig, the same address on Base and Arbitrum (today `0x3CDD9470…bfF1`, 2-of-2) | governance, ratification, unpause |
| `CROSSCHAIN_NAV_UPDATER` | `NAV_UPDATER_ROLE` | NAV service |
| `CROSSCHAIN_EXECUTOR` | `EXECUTOR_ROLE` on vault, agents and strategies | rebalancer bot (and keeper autofund) |
| `CROSSCHAIN_GUARDIAN` | `GUARDIAN_ROLE` | pause and freeze only |
| `CROSSCHAIN_TIMELOCK_DELAY` | seconds, default 86400 | Timelock constructor |

### Deployer funds

| Chain | ETH (gas) | USDC |
|---|---|---|
| Base | ≈ 0.01 ETH | 2 USDC (vault seed + strategy seed) |
| Arbitrum | ≈ 0.01 ETH | 1 USDC (strategy seed) |

Hot wallets (NAV updater, keeper/relayer, executor) need gas on both chains.
The monitor watches their balances through `MONITOR_WATCH_BALANCES`.

### RPC

`BASE_RPC_URL`, `ARBITRUM_RPC_URL` (hardhat) and `RPC_BASE`, `RPC_ARBITRUM`
(services). Use paid providers. Run the monitor on a **different provider**
from the NAV service, so its re-derivation is independent.

The stand uses Moralis nodes (`RPC_BASE`, `RPC_ARBITRUM`, and `ARBITRUM_RPC_URL`
for hardhat). Moralis caps `eth_getLogs` at 100 blocks; the services detect the
cap and adapt (`ops/README.md`, RPC limits), so no setting is needed.

Signed transactions do not go through Moralis: during the Base deployment it
twice accepted a transaction and never propagated it. Services broadcast through
`RPC_SEND_BASE=https://mainnet.base.org` and `RPC_SEND_ARBITRUM=https://arb1.arbitrum.io/rpc`
and read everything else from `RPC_<NETWORK>`. Hardhat deploys use the public
endpoints directly (`BASE_RPC_URL`, `ARBITRUM_RPC_URL`).

## 3. Deployment

```bash
export DEPLOYER_PRIVATE_KEY=...        # deployer only; rotate/retire after phase 3
export CROSSCHAIN_SAFE=0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1
export CROSSCHAIN_NAV_UPDATER=0x... CROSSCHAIN_EXECUTOR=0x... CROSSCHAIN_GUARDIAN=0x...
export CROSSCHAIN_TIMELOCK_DELAY=86400

# phase 1: contracts (each chain)
npx hardhat run deploy/crosschain/01-deploy.ts --network base
npx hardhat run deploy/crosschain/01-deploy.ts --network arbitrum
# phase 2: wiring (needs both manifests)
npx hardhat run deploy/crosschain/02-configure.ts --network base
npx hardhat run deploy/crosschain/02-configure.ts --network arbitrum
# phase 3: handover to Safe + Timelock
npx hardhat run deploy/crosschain/03-handover.ts --network base
npx hardhat run deploy/crosschain/03-handover.ts --network arbitrum
```

**Safe action**, on each chain: call `acceptOwnership()` on the `ProviderManager`
from the manifest.

```bash
# phase 4: read-only verification, must print N/N
npx hardhat run deploy/crosschain/04-verify.ts --network base
npx hardhat run deploy/crosschain/04-verify.ts --network arbitrum
git add deployments/*/crosschain.json && git commit -m "crosschain: deployed"
```

* **Idempotent phases.** Every phase can be re-run after a failure; it sends only
  what is missing.
* **Verification.** Verify the contracts on the explorers with
  `npx hardhat verify` and the args recorded in the manifest.

## 4. Services

Services run only on the server, in Docker: `docs/crosschain-server.md`.

All four services live in `ops/` (TypeScript, ethers v6), with `npm install` in
`ops/`. Each exposes `/health` (200 or 503) and `/status`; the monitor also
exposes `/metrics` (Prometheus). `--once` runs a single pass.

| Service | Command | Key | What it does |
|---|---|---|---|
| NAV updater | `npm run nav` | `NAV_UPDATER_PRIVATE_KEY` | Builds the snapshot across chains and commits a Tick hourly, and immediately when a closed epoch waits for a post-cutoff Tick. While a quarantine already stands it skips a commit whose move still exceeds the refilled bucket — the contract would reject it, so it would settle nothing — and sends one alert per episode rather than one per cadence; `--force` overrides |
| Keeper | `npm run keeper` | `KEEPER_PRIVATE_KEY` (+ `EXECUTOR_PRIVATE_KEY` if `KEEPER_AUTOFUND=true`) | Closes epochs, clears both sides, funds, optionally claims for users and recalls hub-local liquidity |
| Relayer | `npm run relayer` | `RELAYER_PRIVATE_KEY` | Delivers every CCTP transfer (Circle Iris attestation) to the destination agent |
| Monitor | `npm run monitor` | none | 20+ check groups, Telegram alerts on change, independent Tick re-derivation |
| Indexer + API | `npm run indexer` | none | Indexes vault, accountant and agent events into SQLite (a cache, rebuildable); serves `/v1/vault`, `/v1/users/:address`, `/v1/requests/:id`, `/v1/epochs`, `/v1/ticks`, `/v1/allocation`, `/v1/transfers` for the frontend (`INDEXER_DB`, `PORT_INDEXER`, `INDEXER_CORS_ORIGIN`) |

**Common environment:** `RPC_BASE`, `RPC_ARBITRUM`, `CROSSCHAIN_SAFE`,
`CROSSCHAIN_NAV_UPDATER`, `CROSSCHAIN_EXECUTOR`, `CROSSCHAIN_GUARDIAN` (the
monitor verifies roles against them), `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`
(same as the Rebalance-Engine), and ports via `PORT_NAV`, `PORT_KEEPER`,
`PORT_RELAYER`, `PORT_MONITOR`.

**Persistent state.** `TRANSFER_INDEX_FILE` (default `./crosschain-transfer-index.json`)
holds the `BridgeOut`/`BridgeIn` index and the per-chain scan progress, shared by
`nav`, `monitor`, `relayer` and `verify-tick`. It **must live on persistent disk**:
without it every restart re-scans all bridge history from `startBlock`, and because
the commit window is a fixed 256 blocks (about 490 s of usable budget on Base) a
cold start that outgrows that budget makes every commit revert `InvalidHubReference`
— Ticks stop, and settlement and instant exits stop with them. It is written
atomically, bound to a fingerprint of the deployed `ChainAgent` addresses so fork or
stand state can never be loaded by production, and rewound `INDEX_REWIND_BLOCKS`
(default 5000) on load as reorg insurance. `INDEXER_DB` is the API's cache and is
rebuildable. Neither file may be shared between two deployments; the rehearsal
points both into `/tmp/xc-rehearsal`. See `ops/README.md`.

**Hook into the existing healthchecker** (Thesauros-Rebalance-Engine
`apps/healthchecker`):

```
HEALTHCHECK_URLS=...,xc-nav=https://<nav>/health,xc-keeper=https://<keeper>/health,xc-relayer=https://<relayer>/health,xc-monitor=https://<monitor>/health
```

The monitor's `/health` turns 503 while any critical check fails, so the
existing Telegram channel pages on it without extra wiring.

### Monitor checks

| Group | Critical when | Warning when |
|---|---|---|
| RPC | head older than 5 min / RPC failing | head older than 60 s |
| Tick age | older than `maxTickAge` | older than 75% of it |
| Quarantine / freeze | any | — |
| Tick flags | overdue in flight | down-move beyond deposit threshold, in-flight above limit |
| Rate buckets | — | below 10% |
| Tick re-derivation | any of the last 50 committed Ticks does not reproduce from chain data (five verified per pass) | verification error |
| Agent set | the accountant allows any agent on a chain other than exactly the manifest agent (rebuilt from `AgentUpdated`) | — |
| Vault solvency / backing | `cash < pending + reserved`, or USDC balance below cash | — |
| Epochs | clearing stuck more than 6 h, funding stuck more than 72 h | open past max duration + 1 h, clearing more than 2 h, funding more than 24 h, unfunded liabilities |
| Transfers | undelivered for more than 4 × `maxTransit` | undelivered for more than `maxTransit` |
| Strategies | a provider view failing (deposits blocked), or the strategy's Withdraw action paused (blocks recalls and every queued redemption) | a provider above its cap, strategy deposits paused |
| Routes / pauses | — | route disabled or bucket below 10%, any paused domain |
| Governance | any deployment check fails: ProxyAdmin/Timelock owner, implementation code drift, deployer roles, routes, remotes, caps, chain set | — |
| Timelock | — | any queued, unexecuted governance tx (with signature and ETA) |
| Hot wallet gas | — | below `MONITOR_MIN_GAS_WEI` |

## 5. Operations

### Executor (the only role that moves capital)

Every step below is one `npm run exec` command (`ops/README.md`, Operator CLI);
the raw calls are listed for reference.

1. **Deploy capital.** Call `EpochVault.pushToAgent` (the buffer is enforced),
   then `ChainAgent.allocate` into the strategy.
2. **Spread within each chain.** Call `Rebalancer.rebalance` between providers,
   within their caps.
3. **Move across chains.** Call `ChainAgent.bridgeOut(routeId, amount, minReceive, rebalanceId)`.
   Route ids are `keccak256("thesauros.route.v1:<src>-><dst>")`. The relayer
   delivers; then `allocate` on the destination.
4. **Fund redemptions.** On the hub, `deallocate` + `returnToVault` (the keeper
   does this with `KEEPER_AUTOFUND=true`). From a spoke, `deallocate` +
   `bridgeOut` to the hub, then `returnToVault`.

### Guardian (fast, cannot unpause)

| Situation | Action |
|---|---|
| Wrong NAV suspected | `TickAccountant.freeze()` (stops clearing, instant exits, hub sends) |
| Deposit/redeem abuse | `EpochVault.pause(domain)`: 0 deposit requests, 1 redeem requests, 2 deposit clearing, 3 redeem clearing, 4 instant exit, 5 allocate |
| Bridge problem | `ChainAgent.disableRoute(routeId)`, `ChainAgent.pause(1)` (bridge out) on each chain |
| Strategy problem | `ChainAgent.pause(0)` (allocate). Deallocate always stays open |

Claims of funded redemptions, cancels before cutoff, deallocations, returns to
the vault and CCTP deliveries **cannot** be paused. That is by design.

### Safe (ADMIN)

* **Quarantined Tick.** Investigate with `ts-node ops/src/verify-tick.ts <id>`.
  If the move is real and downward, the Safe calls `TickAccountant.ratifyTick(id)`
  at once. A real upward move must be ratified through the Timelock
  (`05-governance-plan.ts`-style queue, 24 h in production); the NAV service keeps
  the Tick the latest meanwhile, because it does not re-commit while the move
  exceeds the bucket. If the move is not real, the NAV service's next honest Tick
  clears it; rotate the NAV key if it was compromised.
* **Lost transfer.** Call `ChainAgent.writeDown(transferId, amount, reason)` on
  the source agent. A late delivery still books the recovery.
* **Freeze and pauses.** `unfreeze()` and `unpause(domain)` after the incident.
* **Roles.** Grant and revoke. Lowering a strategy cap is also allowed directly.

### Timelock (every risk-increasing change)

Change the registry, then run
`npx hardhat run deploy/crosschain/05-governance-plan.ts --network <net>`. It
writes Safe Transaction Builder batches: queue now, execute after the delay,
plus direct ADMIN actions. The monitor shows queued transactions until they
execute.

## 5a. Frontend

`thesauros-app`, branch `feat/crosschain-vault`, page `/crosschain`:

* request deposit (with approve), request redeem, instant exit, claim and cancel;
* the user's requests with statuses;
* the epoch countdown;
* capital per chain and provider;
* the share-price history.

Environment:

```
NEXT_PUBLIC_CROSSCHAIN_VAULT=<EpochVault proxy on Base, from deployments/base/crosschain.json>
NEXT_PUBLIC_CROSSCHAIN_API_URL=<public URL of the ops indexer>
```

The menu item is disabled until both are set.

## 6. Adding a network

1. **Registry and hardhat.** Add the entry to `deploy/crosschain/registry.ts`
   (USDC, CCTP domain — check `localDomain()` —, providers, caps, routes to and
   from its peers) and its hardhat network to `network-config.ts`. Deploy the
   Safe at the same address there first (SEC-019 lesson).
2. **New chain.** Run phases 1, 2, 3 and the Safe `acceptOwnership` on it. Its
   phase 2 wires its own side to the existing chains.
3. **Existing chains.** Run phase 5 on each. It produces the Timelock batch:
   adapter remote, agent peer, routes, and on the hub the accountant chain set
   plus the new agent. The Safe queues it, then executes it after the delay.
4. **Services.** The NAV engine takes the chain set **from the accountant**, so
   it starts including the new chain in the first Tick after `setChains`
   executes, not when the registry changes. Add `RPC_<NEW>` to every service
   before execution.
5. **Verify.** Run phase 4 on all chains, and check that the monitor is green.

## 7. Rehearsal

```bash
BASE_RPC_URL=<archive-capable Base RPC> ops/rehearsal/run.sh   # ~3 minutes
```

**Setup.** It starts two anvil forks with preserved chain ids and generates
fresh keys for every role. It uses the real Safe (impersonated for the
`acceptOwnership` step) and runs all phases.

**CCTP on the forks.** It enables a local attester on the forked CCTP
transmitters. The relayer's `RELAYER_ATTESTATION=local` mode then fills in the
nonce and finality the way Circle does and signs `keccak256(message)`. The burn
on Base and the mint on Arbitrum are the real CCTP V2 contracts.
