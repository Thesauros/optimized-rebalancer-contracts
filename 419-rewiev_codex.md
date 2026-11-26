# TS-419 review: fix package for the implementing agent

You are fixing branch `feat/ts-419-crosschain-ethereum` of
`Thesauros/optimized-rebalancer-contracts`. The findings below come from a code
review of commits `967baab` and `106e905` (base `3df4199`). Line numbers refer to
`106e905`; re-locate them with `grep` if the branch has moved. Implement every
item marked REQUIRED, in the order given, then run the verification section.
Items marked OPTIONAL are recommended but may be deferred. Do not invent extra
scope.

## 0. Context you need

- Cross-chain vault: hub on Base (`EpochVault`, `TickAccountant`), spokes on
  Arbitrum and, with TS-419, Ethereum (`ChainAgent` + a `Rebalancer` strategy on
  each chain), USDC bridged with CCTP V2.
- `deploy/crosschain/registry.ts` is the single registry of networks
  (`NETWORKS`). Deploy phases 01-05 and every ops service read it. Manifests live
  in `deployments/<key>/crosschain.json`; `deployments/mainnet/crosschain.json`
  does NOT exist yet (Ethereum is not deployed).
- Ops services (`ops/src`): `nav` builds and commits Ticks (snapshot of all
  chains, `ops/src/snapshot.ts`), `keeper`, `relayer`, `monitor`, `indexer`,
  `exec` (operator CLI), `preflight` (blocks startup on misconfiguration). They
  run in Docker (`ops/Dockerfile`, `ops/docker-compose.yml`); the server is
  upgraded by hand: checkout a release commit, `docker compose build`, preflight,
  `up -d` (docs/crosschain-server.md).
- TS-419 changed no Solidity contract. Keep it that way: no contract or storage
  layout change belongs in this package.

## 1. Ground rules

- Repository state: the remote `main` currently points at `106e905` (the TS-419
  commits were pushed to `main` by mistake). The owner decides the rollback. Never
  push to `main`. Before any push run
  `git rev-parse --abbrev-ref @{upstream}`; it must be
  `origin/feat/ts-419-crosschain-ethereum`. Push only if the owner asks.
- Another agent may work in the same checkout. Stage files by path
  (`git add <paths>`), never `git add -A`; check `git status` before committing.
- Commits: subject `[ts-419-ethereum-crosschain-spoke] <imperative summary>`, a
  blank line, a short body, a blank line, `Change: ts-419-ethereum-crosschain-spoke`,
  then the trailer `Co-Authored-By: <your model> <noreply@...>` if your harness
  requires one.
- Record what you did in `changes/ts-419-ethereum-crosschain-spoke/verification.md`
  (results table + one line per fixed item) and, where behavior changes, in
  `changes/ts-419-ethereum-crosschain-spoke/design.md`.
- Test commands (from the repo root unless noted):
  - `cd ops && npm test` (Node test runner). Known failure before R8:
    `src/errors.json matches the compiled artifacts`.
  - `npx tsc --noEmit -p ops` (known error: `node:sqlite` types only).
  - `FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile` before `npm test`,
    or the ABI tests are skipped.
  - `forge test --no-match-path 'test/forking/*'` (176 tests pass today).
  - Fork tests: `ETHEREUM_RPC_URL=<archive RPC> forge test --match-path test/forking/CrossChainStrategyEthereum.t.sol`.
    `ethereum-rpc.publicnode.com` serves only ~100 recent blocks and stalls;
    `https://eth.drpc.org` works but its free plan times out under load.

## 2. Findings and required changes

### R1. CRITICAL, REQUIRED: a registry network without a manifest breaks the image build, every service and the monitor

Failure scenario: the branch (or `main`, which contains it now) is checked out on
the server before Ethereum phases 1-3 have produced
`deployments/mainnet/crosschain.json`.
- `ops/Dockerfile:19` `COPY deployments/mainnet/crosschain.json ...` fails, so
  `docker compose build` fails and no release from this branch can be built
  (hotfixes included).
- Without Docker, `loadChains()` (`ops/src/config.ts:120`) throws
  `missing manifest` (`loadManifest`, line 47) and `rpcUrl()` (line 53) throws
  `no RPC for mainnet`: nav, keeper, relayer, monitor, indexer, exec and preflight
  all fail at startup.
- `ops/src/checks/deployment.ts` iterates `NETWORKS` for peers (line 118) and for
  the hub's expected chain set (lines 166-168). The monitor calls it at runtime
  (`ops/src/monitor.ts:234-237`), so an undeployed network pages a failed
  deployment check permanently.

Required change: an explicit opt-in list of networks that are registered but not
deployed yet. A network is left out only if it is in that list AND its manifest
is absent. NAV already fails closed if the accountant tracks a chain the
services do not load (`ops/src/snapshot.ts:462-464`), so leaving the network out
cannot hide capital.

1. `deploy/crosschain/registry.ts`, next to `NETWORKS`:
   ```ts
   /**
    * Registry networks declared not deployed yet: CROSSCHAIN_PENDING_NETWORKS=mainnet.
    * While such a network has no manifest the services leave it out; NAV still
    * refuses a Tick once the accountant tracks it. Deploy phases ignore this list.
    */
   export function pendingNetworks(): Set<string> {
     const keys = (process.env.CROSSCHAIN_PENDING_NETWORKS ?? '').split(',').map((k) => k.trim()).filter(Boolean);
     for (const k of keys) {
       if (!NETWORKS[k]) throw new Error(`CROSSCHAIN_PENDING_NETWORKS: unknown network ${k}`);
       if (NETWORKS[k].role === 'hub') throw new Error('CROSSCHAIN_PENDING_NETWORKS cannot name the hub');
     }
     return new Set(keys);
   }
   ```
   (A function, not a constant, so tests can set the variable after import.)
2. `ops/src/config.ts` `loadChains()`:
   ```ts
   export function loadChains(): Chain[] {
     const pending = pendingNetworks();
     return Object.entries(NETWORKS).flatMap(([key, entry]) => {
       if (pending.has(key) && !fs.existsSync(path.join(manifestRoot(), key, 'crosschain.json'))) return [];
       return [{ key, entry, chainId: entry.chainId, provider: providerFor(key, entry.chainId), manifest: loadManifest(key) }];
     });
   }
   ```
3. `ops/src/checks/deployment.ts`: compute once
   `const deployed = Object.entries(NETWORKS).filter(([k]) => !(pendingNetworks().has(k) && !manifests[k]));`
   and use it instead of `Object.entries(NETWORKS)` / `Object.values(NETWORKS)` at
   lines 118, 166 and 168. Phase 4 (`deploy/crosschain/04-verify.ts`) keeps
   passing all manifests, so its behavior is unchanged when the variable is unset.
4. `ops/src/preflight.ts`: print a warning line for each pending network that was
   left out (`<key> pending: no manifest, left out until phase 1-3 ran`), so the
   operator sees it.
5. `ops/Dockerfile:17-19`: replace the three per-file `COPY deployments/...`
   lines with one line
   ```dockerfile
   # every crosschain manifest .dockerignore lets through; an undeployed network has none
   COPY deployments deployments
   ```
   `.dockerignore` starts with `*` and allowlists only
   `deployments/<key>/crosschain.json`, so nothing else is copied. Keep the
   `.dockerignore` lines as they are.
6. `ops/.env.server.example`: add a commented line
   `# CROSSCHAIN_PENDING_NETWORKS=mainnet   # until deployments/mainnet/crosschain.json is committed`.
7. Runbook `docs/crosschain-deployment.md` §6a ("Order of the service rollout",
   line 333): state that a release containing a registry network without its
   manifest needs `CROSSCHAIN_PENDING_NETWORKS=<key>` on the server, and that the
   variable must be removed once the manifest is committed (with the manifest
   present it has no effect, so forgetting it is harmless).

Tests (`ops/test`): with a temporary `CROSSCHAIN_MANIFEST_DIR` containing only
`base` and `arbitrum` manifests and no RPC for mainnet:
- without the variable `loadChains()` throws `missing manifest`;
- with `CROSSCHAIN_PENDING_NETWORKS=mainnet` it returns base and arbitrum only and
  never calls `rpcUrl('mainnet')`;
- with the variable set and a mainnet manifest present, mainnet is loaded;
- `pendingNetworks()` rejects an unknown key and the hub.
`ops/src/config.ts` reads env at call time, so set `process.env` in the test and
restore it afterwards. If `docker` is available, also check
`docker build -f ops/Dockerfile .` succeeds with no mainnet manifest.

Acceptance: build and services work on this branch before Ethereum is deployed,
given the variable; nothing changes once the manifest exists.

### R2. HIGH, REQUIRED (pre-existing on main, exposure grows with TS-419): one failing provider view on any chain stops Ticks for the whole vault

Facts:
- `Rebalancer.convertToAssets` -> `_convertToAssets` (`contracts/Rebalancer.sol:326`)
  -> `totalAssets()` (line 191) -> `_totalAssetsAtProviders()` (line 928), which
  reverts `ProviderUnavailable` when any provider's `getDepositBalance` fails
  (security remediation "require complete NAV").
- NAV values a strategy position with `strategy.convertToAssets(shares, tag)`
  (`ops/src/snapshot.ts:399`) and only afterwards checks
  `providersHealthy(tag)` (line 400) to apply the documented rule
  (`docs/nav-reproduction.md:102-108`: bid = convertToAssets, offer =
  max(bid, previous accepted offer)). Since `convertToAssets` now reverts, that
  branch is dead: `buildSnapshot` throws, no Tick is committed for any chain, and
  after `maxTickAge` settlement and instant exits halt vault-wide.
- The same revert breaks `ops/src/keeper.ts:94`, `ops/src/monitor.ts:200`
  (`totalAssets()` right after the health check, so the monitor iteration dies
  instead of reporting the `crit`), `ops/src/indexer.ts:560,563` and
  `ops/src/exec.ts:154,221`.
- No ops test covers an unhealthy strategy.
- TS-419 adds five external venues on Ethereum (three MetaMorpho vaults, Comet,
  and Fluid in TS-420), each an independent way to trigger this.

Required change:
1. `ops/src/snapshot.ts` `positionsAt`: read `providersHealthy(tag)` first. If
   healthy, keep `convertToAssets(shares, tag)`. If not, compute the bid without
   `convertToAssets`:
   - `readable = USDC.balanceOf(strategy) + Σ getDepositBalance(strategy, strategy)`
     over `strategy.getProviders(tag)`, each provider call made at `blockTag: tag`
     with `gasLimit: 3_000_000` (mirrors `PROVIDER_VIEW_CALL_GAS`), failures
     counted as 0;
   - `valueBid = totalSupply == 0 ? shares : shares * readable / (totalSupply + feeShares)`,
     rounding down (mirror `_convertToAssetsWithTotals`, Rebalancer.sol:347);
   - `feeShares`: replicate `_accruedFees(readable)` (Rebalancer.sol:588-615) if
     its inputs (management/performance fee, high-water mark, last timestamp) are
     readable through public getters. Cross-chain strategies are initialized with
     both fees 0 (`deploy/crosschain/01-deploy.ts`, `initialize(..., 0, 0, seed)`),
     where feeShares = 0. If the getters do not exist, read the fees through
     whatever public view exists and throw a clear error when a fee is non-zero
     (fail closed rather than overstate the bid).
   - keep `valueOffer = max(valueBid, prev offer)` and the `unhealthy` push.
   The independent verifier (`verifyTick`) uses the same `positionsAt`, so it
   stays consistent automatically. Confirm by reading `verifyTick`.
2. Update `docs/nav-reproduction.md:102-108` to describe the readable-balances
   bid (the old text assumes `convertToAssets` under-states instead of reverting).
3. `ops/src/monitor.ts:198-200`: call `totalAssets()` (and the per-provider cap
   loop after it) only when `healthy`; fix the message on line 199 to
   `"<chain> strategy has a failing provider view: deposits, withdrawals, deallocations and queued redemptions are blocked"`
   (exits revert too: `Rebalancer._withdraw` reverts `ProviderUnavailable`,
   line 399, and exit settlement requires the complete NAV).
4. `keeper.ts:94`, `indexer.ts:560,563`, `exec.ts:154,221`: catch the revert and
   degrade: the keeper skips the funding step for that chain with a logged error,
   the indexer records the value as unknown for that row, and exec prints
   `unavailable (provider view failing)`. None of them may crash the process.

Tests:
- `ops/test`: a unit test for the unhealthy branch with a fake `strategy`
  contract object (as the existing snapshot tests fake providers) whose
  `convertToAssets` throws and `providersHealthy` returns false: the snapshot
  builds, the bid equals the readable-balances formula, and the offer equals
  max(bid, prev).
- Optional Foundry test (`test/unit`): a Rebalancer with one provider mocked to
  revert (`vm.mockCallRevert`) shows `convertToAssets` reverts and
  `providersHealthy()` is false. This pins the contract behavior that the ops
  code now assumes.

Acceptance: with one provider view reverting on one chain, `nav --once` commits a
Tick (offer kept at the previous accepted value for that position) and the
monitor reports `crit` for `strategy.<chain>.health` without crashing.

### R3. HIGH, REQUIRED (runbook): the service upgrade can only be rolled back before the Timelock batches execute

- After the TS-419 services run once, `/data/transfer-index.json` is saved under
  the three-chain fingerprint. A pre-TS-419 release rejects it and re-scans Base
  (≈1.6 M blocks) and Arbitrum (≈11.5 M blocks) from their start blocks: the cold
  start that outlasts the 256-block commit window and stops Ticks.
- After the phase 5 batch executes `setChains`, a pre-TS-419 release cannot
  produce Ticks at all (`accountant tracks chains not configured here`).

Required change, `docs/crosschain-deployment.md` §6a, before "roll the services":
1. Back up the index from the `ops-data` volume before the upgrade, e.g.
   `docker compose -f ops/docker-compose.yml run --rm --entrypoint sh preflight -c 'cp /data/transfer-index.json /data/transfer-index.pre-ts419.json'`
   (verify the entrypoint override works with the image; adapt if not).
2. Rollback before execution = restore that copy, then start the old release.
3. State the point of no return: once the Timelock executes `setChains`, only
   forward fixes are possible.
4. In docs/crosschain-server.md "Upgrading", the existing advice to wipe the
   volume after a contract redeploy must say explicitly: NOT when a network is
   added (the index is kept on purpose).

### R4. MEDIUM, REQUIRED: `REHEARSAL_NETWORKS` can narrow the production registry

`deploy/crosschain/registry.ts:210-217` honours `REHEARSAL_NETWORKS` anywhere. Left
exported in an operator shell or set in `.env.server`:
- phase 5 on Base plans `setChains` without Ethereum. `TickAccountant.setChains`
  has no guard against removing a funded chain; executed, NAV drops by the
  Ethereum share. It is gated only by the Safe and the Timelock delay;
- every service fails (`accountant tracks chains not configured here`).

Required change in `selectNetworks`, after `if (!only) return ALL_NETWORKS;`:
```ts
// A narrowed registry plans setChains without the left-out networks and makes NAV
// refuse every Tick: honour it only for ops/rehearsal/run.sh, whose manifests live in /tmp.
if (!(process.env.CROSSCHAIN_MANIFEST_DIR ?? '').startsWith('/tmp/')) {
  throw new Error('REHEARSAL_NETWORKS is set but CROSSCHAIN_MANIFEST_DIR is not under /tmp: refusing to narrow the registry');
}
```
`ops/rehearsal/run.sh` already exports `CROSSCHAIN_MANIFEST_DIR=/tmp/xc-rehearsal`
before line 129. Test: spawn `node -r ts-node/register/transpile-only -e "require('<abs path>/deploy/crosschain/registry')"`
with `REHEARSAL_NETWORKS=base` and no manifest dir: it must exit non-zero with
that message; with `CROSSCHAIN_MANIFEST_DIR=/tmp/x` it must load.

### R5. MEDIUM, REQUIRED: the hot-wallet gas alert is useless on Ethereum

- `ops/src/monitor.ts:251` uses one threshold for every chain. The default is
  0.005 ETH, and `ops/.env.server.example:43` sets 0.0002 ETH (sized for Base).
- On Ethereum one strategy operation costs 2.4-3.9 M gas (≈0.005-0.02 ETH at
  2-5 gwei), and the relayer pays L1 gas to deliver CCTP transfers. A relayer
  without ETH leaves transfers in flight past `maxTransit` (3600 s).

Required change:
```ts
const minGasFor = (c: Chain) =>
  BigInt(process.env[`MONITOR_MIN_GAS_WEI_${c.key.toUpperCase()}`] ?? process.env.MONITOR_MIN_GAS_WEI ?? '5000000000000000');
```
Use it in the `add(...)` call of that loop (line 256, `b < minGas`). Update the header comment (line 7), add
`MONITOR_MIN_GAS_WEI_MAINNET=100000000000000000` (0.1 ETH) to
`ops/.env.server.example`, and fix `docs/crosschain-deployment.md:105`
("need gas on both chains" -> "on every chain; on Ethereum budget ≥ 0.1 ETH per
hot wallet"). Test: a unit test of the gas check with a fake provider and
per-chain env values.

### R6. LOW, REQUIRED: phase 4 / monitor never check Compound's Comet

`checkDeployment` (`ops/src/checks/deployment.ts`, block at line 151) checks the
ProviderManager owner but not that it maps Compound to the registry Comet.
Inside that block add:
```ts
const pmc = new Contract(c.ProviderManager, ['function getYieldToken(string,address) view returns (address)'], provider);
const comet: string = await pmc.getYieldToken('Compound_V3_Provider', entry.usdc);
check(!entry.strategy.comet || eq(comet, entry.strategy.comet), 'ProviderManager Compound Comet', comet);
```

### R7. LOW, REQUIRED: `RPC_TIMEOUT_MS=""` gives a zero timeout

`ops/src/config.ts:78` `Number(process.env.RPC_TIMEOUT_MS ?? 15_000)` turns an
empty string into 0. Replace with `request.timeout = envNumber('RPC_TIMEOUT_MS', 15_000);`
(`envNumber`, line 155, already treats `''` as unset; function declarations are
hoisted).

### R8. LOW, OPTIONAL (pre-existing on main): the errors.json check is dead

`ops/test/abi.test.ts:44-46` requires `ops/scripts/extract-errors.js`, deleted in
commit `0c420d3` ("correct", 2026-11-04) together with other scripts. Restore it
from `4dbac2f` (`git show 4dbac2f:ops/scripts/extract-errors.js > ops/scripts/extract-errors.js`),
run it, and commit the regenerated `ops/src/errors.json` only if the diff is
limited to errors of contracts the ops services call. Note: the ops image COPYs
`ops/scripts`, which is fine.

### R9. VERIFICATION GAP, REQUIRED before production (not a code change)

Run these and record the results in verification.md:
1. `ETHEREUM_FORK_URL=<paid archive Ethereum RPC> BASE_RPC_URL=https://mainnet.base.org bash ops/rehearsal/run.sh`
   until `REHEARSAL PASSED`. With Ethereum, steps 8 (redemptions), 8b (return path
   Ethereum -> Base through the relayer) and 9 (indexer and API) have never
   passed; free RPCs failed every run at a different point. Keep the machine
   awake (`caffeinate -is`, lid open).
2. The rehearsal exports `CONFIRMATIONS_MAINNET=0` (`ops/rehearsal/run.sh:87`).
   Production uses 12 (Ethereum reference block ≈2.4 min behind). Exercise one
   NAV build with the default by running `nav --once` on the stand (or a fork
   kept advancing) and confirm the commit lands inside the 256-block window.
   Record the NAV iteration duration with three chains on the production RPC
   plan (one shared compute budget per process, `ops/src/config.ts`).
3. Re-run the R1 and R2 tests and the full `npm test`.

### R10. DOCS, OPTIONAL: Ethereum bridging economics

Add to §6a: each Base -> Ethereum transfer costs the relayer L1 gas to deliver,
and each Ethereum strategy operation costs 2.4-3.9 M gas. Bridge to Ethereum in
large tranches (state a minimum, e.g. the amount whose yearly yield difference
covers the round-trip gas several times) and avoid frequent small rebalances.

## 3. Verification checklist

- [ ] R1-R7 implemented with tests; R8 decided; R9 run and recorded.
- [ ] `cd ops && npm test`: everything passes except, if R8 is deferred, the
      errors.json test.
- [ ] `npx tsc --noEmit -p ops`: only the `node:sqlite` error.
- [ ] `forge test --no-match-path 'test/forking/*'` all pass.
- [ ] `git diff --check` clean; no change under `contracts/`.
- [ ] `changes/ts-419-ethereum-crosschain-spoke/verification.md` updated.
- [ ] Afterwards: rebase `feat/ts-420-fluid-ethereum` onto this branch and
      apply `420-rewiev_codex.md` there.

## 4. Out of scope, do not do

- Any Solidity change, including making `totalAssets` non-reverting (that is a
  security-remediation decision and needs an upgrade of live strategies).
- Enabling `maxChainExposure`, adding Aave or Morpho Vault V2 on Ethereum.
- Any live deployment, governance transaction, push to `main`, or force push.
