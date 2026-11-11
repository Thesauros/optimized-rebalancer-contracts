---
title: Ethereum spoke verification
date: 2026-11-11
status: local-validation
project: optimized-rebalancer-contracts
author: cto-agent
---

This is the single acceptance record for TS-419. `docs/crosschain-deployment.md`
points here. `419-rewiev_codex.md` and `419-rewiev_qwen.md` are review inputs, not
records; where they disagree with this file, this file wins, and where this file
cannot produce evidence it says so instead of repeating a claim.

Scope of the 2026-11-11 revision: the open findings from both reviews were
implemented, and the contradictions between the previous version of this file and
§7 of the Qwen review were resolved by re-running every check that can be run
here. No live network, no deployment, no governance transaction, no push.

Environment: macOS, forge 1.8.7 (Homebrew), solc 0.8.33, Node 22, ethers 6.16.0,
worktree `orc-fix-ts419` on branch `fix/audit-ts419` from `3b546e5`. The worktree's
`lib/forge-std` and `lib/morpho-blue` submodules are not initialised; their `src/`
directories are symlinked to the main checkout so both compilers resolve
`remappings.txt`. `forge` still tries to clone them on every invocation and fails;
the failure is noise and does not affect the result. The Docker daemon was not
running in this session.

## Results

Every line below was run in this worktree on 2026-11-11. Exit codes are the real
ones.

| Check | Command | Result | Exit |
|---|---|---|---|
| Foundry build | `forge build` | 128 files compiled, success with warnings | 0 |
| Foundry, non-fork suites | `forge test --no-match-path 'test/forking/*'` | **176 passed, 0 failed, 0 skipped** (11 suites, 132.3 s; re-run after the last edit, 144.4 s) | 0 |
| Fork, Ethereum strategy | `forge test --match-path 'test/forking/CrossChainStrategyEthereum.t.sol'` | **4 passed, 0 failed, 0 skipped** (56.0 s) | 0 |
| Fork, CCTP | `forge test --match-path 'test/forking/CctpV2Adapter.t.sol'` | **3 passed, 0 failed, 0 skipped** (8.2 s), including a real burn from Ethereum finalised by a Base adapter | 0 |
| Hardhat artifacts | `FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile` | 85 Solidity files compiled successfully | 0 |
| ops tests | `cd ops && npm test` | **49 tests, 49 pass, 0 fail, 0 skipped** | 0 |
| ops type check | `cd ops && npx tsc -p tsconfig.json --noEmit` | no output, no errors | 0 |
| deploy tests | `npm run test:deploy` | **23 tests, 23 pass, 0 fail, 0 skipped** | 0 |
| ops image build | `docker build -f ops/Dockerfile .` | **NOT RUN** - no Docker daemon in this session. See "Image build" | n/a |
| full rehearsal | `ops/rehearsal/run.sh` | **NOT RUN** - needs three archive RPCs and ~14 min; see "The rehearsal" | n/a |

The Ethereum fork test ran against `ETHEREUM_RPC_URL=https://ethereum-rpc.publicnode.com`
and passed in 56 s, which matters for the archive-depth question below.

`npm test` reaching 49/49 with zero skips is new. The previous record here said
48/49 with the `src/errors.json matches the compiled artifacts` test failing, and
the Qwen review said the same. It failed because `ops/scripts/extract-errors.js`
had been deleted; `ops/test/abi.test.ts` skips when `artifacts/` is absent, which is
why the failure was invisible to anyone who had not run `npx hardhat compile` first.

## Contradictions between the two review documents, resolved

Four claims contradicted each other. Each was settled by running something, not by
picking a side.

**1. `tsc` and the `node:sqlite` error.** The previous version of this file said
`tsc` reports "only the `node:sqlite` error that main has"; the Qwen review (§7.4)
said it exits 0 with no errors. **The review is right.** `npx tsc -p tsconfig.json
--noEmit` in `ops/` produces no output and exits 0, with the current `node_modules`.
The documented error is gone; do not expect it and do not treat a clean `tsc` as a
regression.

**2. `npm test` 48/49 vs 49/49.** Both were accurate when written. With
`ops/scripts/extract-errors.js` restored and `ops/src/errors.json` regenerated, the
suite is 49/49 with no skips. The failure was pre-existing on `main` and is closed
here (R8 / Q6.2).

**3. `REHEARSAL PASSED`.** The Qwen review (§7.2) states that the rehearsal now
passes end to end and that this closes codex R9, quoting a nine-step log. This file
said steps 8, 8b and 9 had never completed with Ethereum in the set. **The claim is
unverified and is not accepted into this record.** No log, no transfer index, no
indexer database and no monitor dump from that run was committed, and there is no
way to reproduce it from the repository. See "The rehearsal" for what is and is not
proven.

**4. The publicnode archive limitation.** `ops/rehearsal/run.sh:26` says
"publicnode answers only the last ~100 blocks on Ethereum, drpc is archive". The
Qwen review (§7.2, §7.4) says this did not reproduce, that a probe two million
blocks behind head returned data, and that the wording should be dropped. **Both
are partly right, and the distinction decides whether the endpoint is usable.**
Measured directly on 2026-11-11 against `https://ethereum-rpc.publicnode.com`,
head 26,392,367:

| Request | Depth behind head | Answer |
|---|---|---|
| `eth_blockNumber` | - | `0x192b72f` |
| `eth_getBlockByNumber` | 9,615,151 | full block returned |
| `eth_getBalance` | 1, 10, 100 | served |
| `eth_getBalance` | 128, 200, 1 000, 5 000, 20 000, 100 000, 2 000 000 | `-32602 Archive requests require a personal token` |
| `eth_call`, `eth_getLogs` | 9,615,151 | same `-32602` refusal |

So: **block data is served at any depth, archive state is not.** A probe that uses
`eth_getBlockByNumber` to test archive support - the natural thing to reach for, and
the most likely explanation for the review's "did not reproduce" - succeeds at two
million blocks behind head and proves nothing, because a fork needs *state*, not
block headers. The state cutoff is between 100 and 128 blocks. The `run.sh` comment
is correct in substance and imprecise in wording; it stays as it is, since editing
the rehearsal's RPC choice is out of scope for this change.

This also bounds how long a fork can run against that endpoint. An anvil or forge
fork pins one block at startup and serves every later state query at that block, so
the upstream's head walks away from it at Ethereum's ~12 s per block: the pin falls
out of the ~128-block window after roughly 25 minutes. The 56 s fork test above fits
comfortably. A 14-minute rehearsal fits only just, and anything longer cannot work
against publicnode at all. The recommendation to use a paid archive RPC for
`ETHEREUM_FORK_URL` stands, on reliability grounds rather than on the depth claim.

## The rehearsal

`ops/rehearsal/run.sh` was **not run** for this record. It needs three
archive-capable RPCs, about fourteen minutes of uninterrupted machine uptime and
roughly 0.02 ETH of fork traffic; it was explicitly out of bounds for this change.
Nothing below is new evidence.

**Proven in this session:** the code the rehearsal drives compiles, type-checks and
passes every unit, deploy and non-fork suite, plus the Ethereum strategy fork test
that builds the strategy exactly as phase 1 builds it.

**Reported, not reproducible from the repository:** steps 1-7 of the cycle with
Ethereum in the set (deposit, ticks, epoch close, clearing, keeper claim, CCTP
burns Base -> Arbitrum and Base -> Ethereum, relayer delivery, allocation into the
Ethereum strategy, independent Tick re-derivation, monitor clean). Runs 10 and 11
are recorded as having reached that point. No log was committed for either, so this
is a report by the author of the earlier record, not a verifiable result.

**Unproven, and the reason this change is not production-ready:** steps 8, 8b and 9
have never completed with Ethereum in the set in any run recorded here, and the one
claim that they have is unsupported. What each would demonstrate:

* **Step 8 - redemptions.** That `instantRedeem` prices correctly against a
  three-chain NAV (it is the only backward-priced path, so it is where a wrong
  Ethereum bid turns directly into money), and that a queued redemption settles:
  `requestRedeem`, epoch close, a post-cutoff Tick, `clearRedeems`, funding and
  claim, ending with vault liabilities back under 10 units. It is the first test
  that Ethereum capital can leave the vault through the normal user path.
* **Step 8b - the return path.** `deallocate` and `bridgeOut` from each spoke, CCTP
  Ethereum -> Base (domain 0 to domain 6, the direction the hub needs for
  redemptions and the one the fork tests only cover with a synthetic burn), relayer
  delivery, the hub agent's idle balance equalling the sum of both spokes' returns,
  `return all` into vault cash, and a Tick after the round trip that the independent
  verifier re-derives identically. It is the only end-to-end test of the transfer
  index and the consistent cut with capital moving back across three chains.
* **Step 9 - indexer and API.** That the indexer syncs three chains into SQLite and
  that the read API the frontend consumes serves the latest Tick, a user's
  `deposit:claimed` and `redeem:claimed` requests, the instant exit, an allocation
  row with capital on every chain including Ethereum, the Tick history and the
  delivered CCTP transfer. This is what a partner or the app actually sees.

Until those three pass, treat Ethereum as deployed-but-unproven for withdrawals.

**Superseded: the run 10 / 11 / 12 narrative.** The previous version of this file
described those three runs in detail - a fork transport error while mining, a
clamshell sleep that broke DNS on the forks, and a 408 "Request timeout on the free
plan" during phase 1 on Ethereum. That narrative is superseded and is not carried
forward. What survives it is only this: all three failures were environmental
(upstream RPC limits and machine sleep), not defects in the TS-419 code, and each
run reached a different point, which is the signature of a free-endpoint problem
rather than a reproducible bug. Two code changes did come out of those runs and are
still in the tree: `evm_mine` retries on fork upstream errors in the rehearsal
driver, and the transfer index no longer rewinding below a manifest's `startBlock`
(see "Defect found by the rehearsal").

### Rehearsal environment vs production

The rehearsal overrides five values that production sets differently. A pass under
the rehearsal's settings does not exercise any of the production ones, so each is a
gap rather than a pass. None was separately exercised for this record.

| Variable | Rehearsal (`ops/rehearsal/run.sh`) | Production default | Defined in | Production value exercised? |
|---|---|---|---|---|
| `CONFIRMATIONS_BASE` | 1 (line 87) | 10 | `deploy/crosschain/registry.ts` | no |
| `CONFIRMATIONS_ARBITRUM` | 0 (line 87) | 20 | `deploy/crosschain/registry.ts` | no |
| `CONFIRMATIONS_MAINNET` | 0 (line 87) | 12 | `deploy/crosschain/registry.ts` | no |
| `RPC_TIMEOUT_MS` | 180000 (line 92) | 15000 | `ops/src/config.ts` | no |
| `LOG_RANGE` | 2000 (line 90) | 9000 | `ops/src/util.ts` | no |

`CONFIRMATIONS_MAINNET=12` is the one that changes behaviour rather than only
timing: the hub reference block sits about 2.4 minutes behind head, so a NAV
iteration has to finish inside a 256-block commit window measured from an older
block. That needs one `nav --once` against production settings on the stand, and it
has not been done.

`INDEX_REWIND_BLOCKS` is **not** a divergence: the rehearsal never sets it and
`ops/src/snapshot.ts` defaults it to 5000, so both use the same value.

## Image build

The image could not be built from this branch before this change, for two
independent reasons, and both are fixed:

* `ops/Dockerfile` named `deployments/mainnet/crosschain.json`, which does not exist
  anywhere in the tree because the Ethereum spoke has never been deployed. It now
  copies `deployments` once, and `.dockerignore`'s deny-all allowlist admits
  `deployments/*/crosschain.json` by glob instead of naming three chains.
* `ops/Dockerfile` also copies `ops/scripts`, which commit `0c420d3` deleted along
  with 1435 other lines. The directory is restored.

Verified here, statically: every `COPY` source in `ops/Dockerfile` exists in the
tree (`ops/package.json`, `ops/package-lock.json`, `ops/tsconfig.json`, `ops/src`,
`ops/scripts`, `deploy/crosschain/registry.ts`, `deployments`), and
`deployments/mainnet/crosschain.json` is still absent - so the build no longer
depends on it. **Not verified here:** an actual `docker build`, and therefore also
not verified that the `.dockerignore` glob admits the two existing manifests and
nothing else. The mechanism is unchanged from the per-chain lines that demonstrably
worked before, so the risk is low, but the build should be run once before this
release is deployed.

The runtime check is unchanged and still fails closed: `loadManifest` throws
`missing manifest <path>`, so a service started against a registry network with no
manifest dies at startup rather than silently ignoring a chain.

## Fixed in this change

One line per item; the finding identifiers are those of `419-rewiev_codex.md`
(`R*`) and `419-rewiev_qwen.md` (`Q*`).

* **R1 / Q6.1 / C1** - `ops/Dockerfile` copies `deployments` once and
  `ops/scripts`, which is restored; `.dockerignore` allowlists
  `deployments/*/crosschain.json` by glob. The image builds with or without the
  Ethereum manifest, and `ops/src/config.ts` still throws `missing manifest`.
* **R2** - `ops/src/snapshot.ts` reads `providersHealthy` before it asks for a
  price. `convertToAssets` reverts `ProviderUnavailable` while any provider view
  fails, so the old order made the degraded branch dead code and threw the whole
  snapshot out. The degraded path now prices the position from readable balances
  (`priceSharesFromReadableBalances`) and fails closed: it throws on an unreadable
  provider balance and on a non-zero management or performance fee rather than
  under- or over-reporting NAV.
* **R3** - `docs/crosschain-deployment.md` §6a now has a transfer-index backup step,
  a rollback procedure, and names the point of no return (the Timelock executing
  `setChains` on Base). The "too early is impossible" bullet was corrected: the
  image now builds before step 1, so what fails early is service startup, not the
  build.
* **R4** - `deploy/crosschain/05-governance-plan.ts` refuses to plan a `setChains`
  that drops a chain the accountant already tracks, names the chain, and requires
  `CROSSCHAIN_ALLOW_DROP_CHAINS=1` to override. `deploy/crosschain/registry.ts`
  exports `fullNetworks()` for the comparison. No on-chain guard was added.
* **R5** - `ops/src/monitor.ts` reads the gas threshold per chain
  (`MONITOR_MIN_GAS_WEI_<KEY>`, falling back to `MONITOR_MIN_GAS_WEI`, then to
  0.005 ETH); `ops/.env.server.example` sets `MONITOR_MIN_GAS_WEI_MAINNET` to
  0.1 ETH; the runbook's "gas on both chains" is corrected.
* **R6** - `ops/src/checks/deployment.ts` phase 4 now reads
  `ProviderManager.getYieldToken("Compound_V3_Provider", usdc)` and compares it with
  `entry.strategy.comet`; `ops/test/registry.test.ts` cross-checks every registry
  Comet against `utils/constants.ts`, the table the live single-chain vaults were
  deployed from.
* **R7** - `ops/src/config.ts` uses `envNumber('RPC_TIMEOUT_MS', 15_000)`, so an
  empty string means unset instead of a zero timeout.
* **R8 / Q6.2** - `ops/scripts/extract-errors.js` restored and
  `ops/src/errors.json` regenerated: 76 -> 97 selectors, purely additive. The 21
  added are all seven `Timelock__*` errors, the five provider-removal errors
  (`ProviderHasAssets`, `ProviderHasReceiptShares`, `ProviderSourceChanged`,
  `DuplicateProviderSource`, `SecurityAccountingNotInitialized`), two `Ownable*`
  errors and seven provider and vault errors. `ops/src/exec.ts` can now name a
  Timelock revert for an operator.
* **Q1** - `ops/src/preflight.ts` fails, not warns, when the URL that would carry
  `eth_sendRawTransaction` for a loaded chain is a known free shared endpoint
  (`OPS_ALLOW_PUBLIC_SEND_ENDPOINT=1` downgrades it to a warning for a paid tier on
  a listed host); `ops/.env.server.example` no longer defaults `RPC_SEND_MAINNET` to
  publicnode; the runbook explains why Ethereum differs from the two L2s here.
* **Q3** - `ops/rehearsal/e2e.ts` derives the expected spokes from the registry
  instead of asserting `spokes.length === 2`, and keeps the Ethereum-specific half.
* **Q5** - the `maxChainExposure` comment in `deploy/crosschain/registry.ts` and
  §6a "Left out on purpose" now state the same decision: the cap stays disabled
  with three chains because there is no target allocation to size it against, and
  the accepted consequence is written down.
* **Q6.3** - `ops/README.md` no longer documents `xc-watchdog.service`,
  `xc-watchdog.cron` or `autofix-watchdog.py`. Those files were not resurrected.

No Solidity was changed, so `ops/src/errors.json` changed only because the
extraction list changed, not because a contract did. `git diff --stat` touches
nothing under `contracts/` or `test/`.

## Defect found by the rehearsal

Still true, still in the tree, fixed before this revision. The transfer index
rewinds a saved scan mark 5000 blocks against reorgs. A mark taken soon after
deployment then scanned below the manifest's start block, where the agent has no
events. On a fork those blocks are served by the upstream RPC; the public Base
endpoint answered 429 and NAV failed. The scan now starts no lower than the start
block, as `EventCache` already does. Present on `main`; harmless on a live chain
apart from wasted log queries.

## Measured on the Ethereum fork

Deployer, phases 1-3: 31 transactions, 16.7 M gas (0.017 ETH at 1 gwei, 0.08 ETH at
5 gwei). Strategy deposit 2.4 M, withdraw 2.8 M, rebalance 3.9 M gas; the Smokehouse
view 1.2 M, under the 3 M provider view stipend. Measured in the 2026-11-04 run, not
re-measured here.

## Open items

* **Steps 8, 8b and 9 with Ethereum in the set.** The blocking gap; see above. Needs
  a paid archive Ethereum RPC and an awake machine.
* **`docker build -f ops/Dockerfile .`** has to be run once, with and without a
  mainnet manifest, before this release is deployed. Not possible in this session.
* **`ops/src/util.ts` has no dedicated test suite.** `ops/test/util.test.ts`
  (328 lines) was deleted by `0c420d3`; `LOG_RANGE`, `scanMany`, `EventCache` and
  `retryTransient` are still there and are now exercised only indirectly, by the
  snapshot and indexer tests. Coverage was removed without removing the code.
* **Nothing guards a `COPY` source that does not exist.** Both halves of the image
  build failure were dangling references that only a build would catch, and CI has
  no docker build (`.github/workflows/` holds only `security.yml`). A test asserting
  that every `COPY` source in `ops/Dockerfile` exists in the repository would have
  caught both at commit time. Not added here: it was not in scope for this change.
* **`TickAccountant._setChains` has no on-chain guard against dropping a chain.**
  The R4 refusal is off-chain only, so it protects phase 5 and nothing else: a hand
  built `setChains` batch still removes a funded chain if the Safe signs it. Adding
  a guard is a contract change to a live proxy and was deliberately not made.
* **`maxChainExposure` stays at 0 with three live chains.** Accepted risk, recorded
  in `registry.ts` and §6a.
* **Q2 (preflight chain-id assertion) was not implemented** - it is not part of this
  change's scope, and the gap it describes is narrower than the review states:
  `preflight.checkRpc` already calls `eth_chainId` on both the read and the send URL
  of every loaded chain and fails on a mismatch, and `ops/docker-compose.yml` makes
  every service wait on `preflight` completing successfully.
* **Q4 lives in `Thesauros-Rebalance-Engine`** (the allocator does not weigh L1 gas,
  and that repository has no Ethereum `crosschain` entry). Nothing was changed here
  and the Ethereum entry must be transcribed from the real
  `deployments/mainnet/crosschain.json` once phases 1-3 produce it, never from the
  registry.

## Not verified here

Live deployment, the production rollout order (queue, roll services, execute) and
the production values of the five divergent variables above. All remain operator
steps; §6a of `docs/crosschain-deployment.md` is the runbook.
