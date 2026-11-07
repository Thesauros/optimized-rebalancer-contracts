# TS-419 review (Qwen): supplement to 419-rewiev_codex.md

You are fixing branch `feat/ts-419-crosschain-ethereum` of
`Thesauros/optimized-rebalancer-contracts`. This file is a SUPPLEMENT, not a
replacement. `419-rewiev_codex.md` is the primary package for this branch; read
it first and execute its R1-R10. This file adds findings that review did not
cover, refines three of its fixes, and lists code you must not break.

Review basis: commits `967baab` and `106e905` (base `3df4199`), plus a
cross-repository read of `Thesauros-Rebalance-Engine` and
`thesauros-vault-data-service`. Code line numbers refer to `106e905`; the only
later commit on this branch adds a markdown file. Line numbers drift - locate
targets by symbol name with grep.

Numbering: `Q*` items are mine, `R*` and `C*` refer to codex's package and to
corrections of it.

## 0. Execution order

1. Execute codex R1-R7 in the order given there. R1 is CRITICAL and blocks every
   release from this branch, including unrelated hotfixes.
2. Apply the refinements C1-C3 below ON TOP of R1, R4 and R9. They modify those
   fixes; they do not replace them.
3. Then execute Q1-Q5.
4. Q4 lives in `Thesauros-Rebalance-Engine` and is not blocked by anything here.
5. Run codex R9 and the combined verification in section 4.
6. Afterwards rebase `feat/ts-420-fluid-ethereum` and apply `420-rewiev_codex.md`
   plus `420-rewiev_qwen.md` there.

## 1. Ground rules

- Never push. `origin/main` already points at `106e905`, which is this branch's
  code pushed by mistake; the rollback is the owner's decision, not yours. If a
  push is ever requested, first confirm
  `git rev-parse --abbrev-ref @{upstream}` is
  `origin/feat/ts-419-crosschain-ethereum`.
- Another agent works in this repository and has created other branches from the
  same commit. Stage by path. Never `git add -A`. Run `git status --porcelain`
  before every commit and confirm you are adding only your own files.
- TS-419 changed no Solidity. Keep it that way. No contract or storage layout
  change belongs in this package.
- Commits: `[ts-419-ethereum-crosschain-spoke] <summary>`, body, blank line,
  `Change: ts-419-ethereum-crosschain-spoke`, then your harness co-author trailer.
- No emojis in documentation or comments. Use plain words or `[x]` / `[ ]`.
- Never invent a value where real data is absent. If a check cannot run (no paid
  archive RPC, no Docker), record it as SKIPPED with the reason in
  verification.md. Never record a pass you did not observe.

## 2. Refinements to the codex package

### C1. Refines R1 step 5: the `.dockerignore` allowlist must stop being per-chain

Codex R1.5 correctly replaces the three `COPY deployments/<key>/crosschain.json`
lines with one `COPY deployments deployments`, and correctly notes the existing
`.dockerignore` allowlist keeps everything else out. Verified: the committed
`.dockerignore` is

```
# allowlist: the ops image needs only these (see ops/Dockerfile)
*
!ops/package.json
!ops/package-lock.json
!ops/tsconfig.json
!ops/src
!ops/scripts
!deploy/crosschain/registry.ts
!deployments/base/crosschain.json
!deployments/arbitrum/crosschain.json
!deployments/mainnet/crosschain.json
```

and `ops/Dockerfile:19` is the line that copies the manifest which does not
exist. Both files on disk are IDENTICAL to HEAD.

Do not stop there. The allowlist is hardcoded per chain, so the fourth network
re-breaks the image build in exactly the same way R1 describes - a missing
`COPY` source, or a manifest silently absent from the image. Replace the three
lines with one glob:

```
!deployments/*/crosschain.json
```

Docker's ignore syntax supports `*` for a single path segment, so this matches
exactly `<key>/crosschain.json` under `deployments/` and nothing else. `solcInputs`
and the per-provider records stay excluded. Verify with
`docker build -f ops/Dockerfile .` and then
`docker run --rm <image> ls -R deployments` - the output must list only
`crosschain.json` files.

Note the allowlist has no `!deployments/ADDRESSES.md` line and the Dockerfile
does not copy it. That is consistent; do not add it.

### C2. RETRACTED - do not gate the registry narrowing on PROFILE

An earlier revision of this file proposed adding a second condition to codex R4:

```ts
// DO NOT IMPLEMENT - this breaks the rehearsal
if (only && PROFILE === 'production') { throw new Error(...); }
```

That proposal rested on a false premise and is withdrawn. The premise was that
the rehearsal runs under `CROSSCHAIN_PROFILE=stand`. It does not.
`ops/rehearsal/run.sh`, verified by grep:

```
50: PROFILE=${REHEARSAL_PROFILE:-production}
51: export CROSSCHAIN_PROFILE=$PROFILE
```

The DEFAULT rehearsal profile is `production`; `stand` requires an explicit
`REHEARSAL_PROFILE=stand`. The narrowing is exported at line 129
(`REHEARSAL_NETWORKS=base,arbitrum`) while that production profile is in force,
and unset only at line 151. The proposed guard would therefore throw on every
default rehearsal run, in stage 1, before anything is deployed.

Implement codex R4's `/tmp` gate as written and add no PROFILE condition:

```ts
if (only && !(process.env.CROSSCHAIN_MANIFEST_DIR ?? '').startsWith('/tmp/')) {
  throw new Error('REHEARSAL_NETWORKS is rehearsal-only; it would narrow the production registry');
}
```

It is correct precisely because the rehearsal exports
`CROSSCHAIN_MANIFEST_DIR=/tmp/xc-rehearsal` (run.sh:66) and production does not.
That is a property of the deployment rather than of the profile, so it does not
collide with the rehearsal's use of the production profile.

If a second, independent condition is wanted, key it on something the rehearsal
sets and production never does - for example require an explicit
`CROSSCHAIN_ALLOW_NARROWING=1` alongside the `/tmp` manifest dir. Do not key it
on PROFILE.

Restating codex R4's severity because it is the sharpest consequence in either
package: a narrowed registry makes phase 5 on the hub plan `setChains` WITHOUT
Ethereum, and `TickAccountant.setChains` has no guard against removing a funded
chain. Executed through the Timelock, NAV drops by the whole Ethereum share.
This is a fund-accounting failure reachable from one stray environment
variable, gated only by the Safe and the delay.

### C3. Extends R9.2: five rehearsal overrides diverge from production, not one

Codex R9.2 identifies `CONFIRMATIONS_MAINNET=0` against production's 12. The
full set, each value verified by grep against `run.sh` and against the source of
the production default:

| Variable | run.sh | Production default | Default defined in |
|---|---|---|---|
| `CONFIRMATIONS_BASE` | 1 (line 87) | 10 | `deploy/crosschain/registry.ts:132` |
| `CONFIRMATIONS_ARBITRUM` | 0 (line 87) | 20 | `deploy/crosschain/registry.ts:164` |
| `CONFIRMATIONS_MAINNET` | 0 (line 87) | 12 | `deploy/crosschain/registry.ts:201` |
| `RPC_TIMEOUT_MS` | 180000 (line 92) | 15000 | `ops/src/config.ts:78` |
| `LOG_RANGE` | 2000 (line 90) | 9000 | `ops/src/util.ts:113` |

So confirmations diverge on ALL THREE chains, not only Ethereum, and two further
variables diverge that R9.2 does not mention. Extend R9.2 so verification.md
records, for each of the five, whether the production value was separately
exercised. Where it was not, record a gap rather than a pass.

Correction to an earlier revision of this file: it listed
`INDEX_REWIND_BLOCKS=5000` as a rehearsal override. It is not one. `run.sh`
never sets that variable, and `ops/src/snapshot.ts:19` defaults it to 5000, so
rehearsal and production use the SAME value. It is not a divergence and needs no
action. The earlier revision also gave `RPC_TIMEOUT_MS` as 600000; the real
value is 180000.

Related, and worth folding into R7: `RPC_TIMEOUT_MS` has no upper bound and no
validation. `envNumber` already treats an empty string as unset, which is what
codex R7 uses to fix the zero-timeout bug. Consider bounding the production
value while you are in that function. The rehearsal runs at 180000, twelve times
the production default, so one hung RPC can block a single request for three
minutes. Section 7 records an observed hang of over 18 minutes at
`await tx.wait()` in `ops/src/exec.ts:109` during the 420 rehearsal. If you
bound the value, exempt the rehearsal by manifest dir rather than by profile
(see the retraction in C2), and confirm `run.sh` still passes.

### C4. Corrects a claim about `.env.server.example`

An earlier review of this branch stated that both the read and the send endpoint
for Ethereum are public. That is wrong. Verified by grep on the committed file:

```
9:  RPC_MAINNET=https://site2.moralis-nodes.com/eth/<project-id>
12: RPC_SEND_MAINNET=https://ethereum-rpc.publicnode.com
```

Reads are already a paid-provider placeholder, consistent with Base and
Arbitrum. Only the SEND path is public. Q1 is scoped accordingly. Do not
"fix" `RPC_MAINNET`.

### C5. Corrects a claim about withdrawal failure handling

An earlier review of this branch stated that a provider withdrawal failure kills
the whole operation. That is true only for the rebalance path. Verified in
`contracts/Rebalancer.sol`:

- `_withdraw` (the redemption path) loops providers and TOLERATES failure:
  `(bool success,) = address(provider).delegatecall(...)` guarded by
  `if (success)`, with the in-code comment "continue to next provider instead of
  reverting the entire tx." A shortfall across all providers ends in
  `InsufficientLiquidity`.
- `rebalance` does NOT tolerate it: `_delegateActionToProvider` ends in
  `address(provider).functionDelegateCall(data)`, which propagates. One bad leg
  fails the whole batch.
- Both paths hard-revert on a failing VIEW: `_safeGetDepositBalance` with
  `ok == false` gives `ProviderUnavailable` in `_withdraw` and `InvalidProvider`
  in `rebalance`.

This matters for codex R2.3, which rewrites the monitor message about blocked
exits. The message must reflect that a failing provider VIEW blocks exits
(`ProviderUnavailable`), which is the case R2 describes - not that a failing
withdrawal ACTION blocks them, which it does not.

## 3. Q findings

### Q1. MEDIUM, REQUIRED: the Ethereum send path is a public endpoint

`ops/.env.server.example` line 12 sets
`RPC_SEND_MAINNET=https://ethereum-rpc.publicnode.com`.

Two distinct problems:

1. Transaction privacy. `ops/src/config.ts` routes every
   `eth_sendRawTransaction` to `RPC_SEND_*` through `RoutedProvider._send`. On
   Ethereum, submitting signed bridge and allocate transactions through a public
   node exposes them to the public mempool before inclusion. Base and Arbitrum
   already use public send endpoints (`https://mainnet.base.org`,
   `https://arb1.arbitrum.io/rpc`), but Ethereum is where mempool exposure
   actually carries value.
2. Reliability. This branch's own `verification.md` records runs 10, 11 and 12
   failing on exactly this class of endpoint - 408 "Request timeout on the free
   plan" and 429. A dropped `eth_sendRawTransaction` on the relayer path leaves
   a CCTP transfer in flight past `maxTransit`.

Required: change the example to a paid provider placeholder in the same style as
line 9, and recommend a private or protected transaction channel for the
Ethereum send path specifically. State in `docs/crosschain-deployment.md` §6a,
next to the RPC paragraph that already says "Use paid providers", that the send
path on Ethereum has a mempool-exposure consideration the read path does not.

Do not change the Base or Arbitrum send endpoints in this task. That is a
separate decision with a different risk profile.

### Q2. LOW, REQUIRED (decision): `staticNetwork: true` removes chain-mismatch detection

`readRequest()` in `ops/src/config.ts` gained `staticNetwork: true`. In ethers
6.16.0 (the pinned version in `ops/package.json`) that makes the provider trust
the chainId passed to its constructor and skip `_detectNetwork()`. Previously a
mistyped `RPC_MAINNET` pointing at another chain would surface as a network
mismatch at first use; now it will not.

There is a compensating control: `ops/src/checks/deployment.ts` compares
on-chain contract addresses against the registry, so the monitor reports a
failed deployment check for a wrong-chain RPC. It is loud, but it is late - it
fires after services start rather than at construction.

`ops/src/preflight.ts` already exists to block startup on misconfiguration and
already validates the profile against the manifest. That is the natural home for
a direct check. Required: add a one-shot assertion in preflight that
`provider.getNetwork().chainId` equals the registry `chainId` for every loaded
chain, failing with a message naming both values. Cost is one `eth_chainId` per
chain at startup.

If the owner prefers to accept the risk instead, record that decision in
`changes/ts-419-ethereum-crosschain-spoke/design.md` with the compensating
control named. Do not leave it implicit.

### Q3. LOW, REQUIRED: the rehearsal hardcodes the spoke count

`ops/rehearsal/e2e.ts` line ~76:

```ts
assert(spokes.length === 2 && spokes.some((c) => c.chainId === 1n), `spokes: ${spokes.map((c) => c.key).join(', ')}`);
```

This fails the day a fourth network is added, with a message that reads like a
real failure. The rest of the file is already dynamic - lines ~118, ~172 and
~221 all derive from `spokes.length`. Change `=== 2` to `>= 2` and keep the
Ethereum-specific half of the assertion, which is the part that actually
belongs to TS-419.

### Q4. HIGH, REQUIRED (different repository, pairs with 420 Q1): the allocator does not weigh L1 gas, and the engine has no Ethereum cross-chain entry

Codex R5 fixes the MONITORING side (one gas-alert threshold for all chains is
useless on Ethereum) and codex R10 documents the ECONOMICS in the runbook.
Neither makes the allocation DECISION gas-aware. That gap is in
`Thesauros-Rebalance-Engine`.

Evidence, quoted from `libs/networks/src/deployments.ts`, on the existing
Ethereum vault entry:

```
readOnly: true,
// The bot holds no ETH here, and the allocator weighs a move against the
// APR threshold only, not against what the move costs in L1 gas.
```

Against this branch's own fork measurements, recorded in
`changes/ts-419-ethereum-crosschain-spoke/verification.md` and in §6a: strategy
`deposit` 2.4 M gas, `withdraw` 2.8 M, `rebalance` 3.9 M. At 2-5 gwei that is
roughly 0.005-0.02 ETH per operation. A move that clears the APR threshold can
still be net-negative once L1 gas is counted, and TS-419 is what puts capital
where that trade-off becomes real.

Second half of the same finding: `deployments.ts` has `crosschain` blocks for
two networks only. There is no `crosschain` entry for `[NetworkEnum.Ethereum]`,
even though `slug: 'mainnet'` is already set there and
`getCrosschainDeployment` reads `join(dir, deployments[network].slug, 'crosschain.json')`.
`listCrosschainNetworks()` filters out networks without a `crosschain` block, so
Ethereum is currently invisible to the engine's cross-chain view.

Required:
1. Record an explicit owner decision on whether Ethereum enters the automated
   allocation path before a gas term exists. If it does not, say so in §6a and
   keep the engine's Ethereum posture read-only. If it does, add the gas term:
   estimated gas times base fee times ETH price, compared against the expected
   yield delta over the intended holding horizon, not against a bare APR
   threshold.
2. The Ethereum `crosschain` entry must be transcribed from the real
   `deployments/mainnet/crosschain.json` once phase 1-3 produce it. Do not write
   it from `deploy/crosschain/registry.ts` and do not guess any address. This
   repository's own rule is that the deployment record is authoritative, and
   `ops/test/registry.test.ts` already enforces it for reused providers.
3. Add an assertion that the engine's static provider list length equals the
   on-chain `getProviders()` length for every tracked vault. `pool-multi.ts`
   zips `balances[]` and `depositRates[]` POSITIONALLY to produce the published
   APY, so a length or order mismatch does not throw - it silently pairs the
   wrong balance with the wrong rate. See `420-rewiev_qwen.md` Q1 for the Fluid
   half of this.

### Q5. DECISION FOR THE OWNER, no code change requested: `maxChainExposure` comment now contradicts the runbook

`deploy/crosschain/registry.ts`, in `COMMON_ACCOUNTANT`:

```ts
// Set it through the Timelock once a target allocation exists or a third chain is
// added (`05-governance-plan.ts`). `0` disables the concentration cap; ...
maxChainExposure: 0n,
```

TS-419 adds the third chain. The condition in the comment is now met and the
action was not taken. `docs/crosschain-deployment.md` §6a says the opposite
under "Left out on purpose": "`maxChainExposure` stays disabled; enabling it is
a separate Timelock decision." Codex lists enabling it under "Out of scope, do
not do".

This is not a request to reopen the scope. It is a report that the COMMENT is
now stale and actively misleading: the next reader of `registry.ts` will believe
the cap is scheduled to be on, while §6a says it is deliberately off. With three
live chains and per-provider caps on Ethereum summing to 120 percent on this
branch (`CompoundV3` 5000, `GauntletPrimeMorpho` 4000, `SmokehouseMorpho` 3000,
entry uncapped) - and 150 percent once TS-420 adds `Fluid` 3000 - there is
currently no on-chain ceiling on how much of the vault can sit on one chain.

Required, minimally: rewrite the comment so it states the current decision and
points at §6a, instead of promising an action that was declined. Whether to set
a real value is the owner's call and should be recorded as an accepted risk if
it stays at 0.

### Q6. HIGH, REQUIRED: commit `0c420d3` deleted 1435 lines of ops tooling and left dangling references. This is the root cause of BOTH the second Docker failure and the ops test failure.

Found while reproducing the build. `git show --stat 0c420d3`:

```
commit 0c420d38de33293df8a952d7710b84ce316dc5a2
Author: Ivan Borisov <2622610@gmail.com>
Date:   Wed Nov 4 21:18:49 2026 +0200
    correct
 16 files changed, 1435 deletions(-)
```

All deletions, no additions. Among them:

| Deleted | Lines | Still referenced by |
|---|---|---|
| `ops/scripts/extract-errors.js` | 30 | `ops/test/abi.test.ts:46` (`require('../scripts/extract-errors.js')`), `ops/src/exec.ts:54` (comment only), `ops/Dockerfile:15`, `.dockerignore:7` |
| `ops/scripts/autofix-watchdog.py` | 275 | `ops/README.md:74` and `:90`, which document it as a live health check on a 00:00/02:00 UTC cron and give a `--check` command |
| `ops/scripts/install-autofix-watchdog.sh` | 32 | - |
| `ops/scripts/execute-buffer-governance.sh` | 17 | - |
| `ops/deploy/xc-watchdog.service`, `.cron` | 25 | `ops/README.md`, four mentions of `xc-watchdog` |
| `ops/governance/*` (README, two buffer batches, systemd unit + timer) | 294 | - |
| `ops/src/prepare-buffer-10pct.ts` | 197 | - |
| `ops/test/util.test.ts` | 328 | - |
| `ops/test/prepare-buffer-10pct.test.ts`, `ops/test/test_autofix_watchdog.py` | 237 | - |

Two consequences that are live on `main` right now, independent of TS-419:

1. **The ops image has a SECOND unbuildable COPY.** `ops/Dockerfile:15` is
   `COPY ops/scripts ops/scripts`, and `ops/scripts/` does not exist in a fresh
   checkout. Proven by experiment in section 7.1: with the mainnet line removed,
   the build fails at `COPY ops/scripts`. So codex R1's fix alone does NOT
   produce a buildable image. Both sources must be addressed.
2. **The operations runbook documents a watchdog that is not in the
   repository.** `ops/README.md` tells an operator to run
   `python3 ops/scripts/autofix-watchdog.py --check` and describes a cron that
   checks all five health endpoints. On a fresh clone that file is absent.

Note on the untracked copy: `ops/scripts/extract-errors.js` exists on disk in
the main worktree (1016 bytes, mtime 2026-11-07 09:50:30) as `?? ops/scripts/`.
It is NOT gitignored (`git check-ignore` returns nothing) and it is NOT present
in a fresh worktree or in the `orc-fix-convert-to-assets` worktree. So it was
recreated locally after the deletion and never re-added. Do not assume it is
committed; do not assume the on-disk copy is the same as the deleted 30-line
version - compare against `git show bdb0c7d:ops/scripts/extract-errors.js`
before trusting it.

Required:
1. Decide, per file, restore or delete-the-reference. `git show <commit>:<path>`
   recovers any of them; `bdb0c7d` is the last commit that had all four scripts.
   A commit whose entire message is "correct" and which removes a 328-line test
   file, a 275-line watchdog and 197 lines of source is not self-documenting -
   if the removal was intentional, record why in `ops/README.md` and delete the
   references; if not, restore.
2. `ops/test/util.test.ts` (328 lines) deserves specific attention. If it tested
   `ops/src/util.ts`, which still exists and still holds `LOG_RANGE`, then
   deleting the test removed coverage without removing the code. Confirm whether
   `util.ts` is now untested and restore the test if so.
3. Commit `ops/scripts/extract-errors.js` so `abi.test.ts` and the Dockerfile
   resolve. This single action closes codex R8 AND the second half of the Docker
   build failure. Then re-run `node ops/scripts/extract-errors.js` and commit the
   regenerated `ops/src/errors.json` in the same commit, as R8 asks.
4. Fix `ops/README.md` to match whatever survives. A runbook that points at
   absent tooling is worse than no runbook, because it is trusted during an
   incident.
5. Add a guard so this cannot recur silently: a test asserting that every path
   named in a `COPY` line of `ops/Dockerfile` exists in the repository. It is a
   few lines and it would have caught both missing sources at commit time rather
   than at deploy time. CI currently has no docker build (`.github/workflows/`
   contains only `security.yml`), so nothing else catches it.

## 4. Verification (combined, runs after codex section 3)

- [ ] codex R1-R7 implemented with tests; R8 decided; R9 run and recorded.
- [ ] C1 applied: `.dockerignore` uses `!deployments/*/crosschain.json`;
      `docker build -f ops/Dockerfile .` succeeds with NO mainnet manifest
      present, and the image's `deployments/` contains only `crosschain.json`
      files. Docker is available on this machine (server 29.8.2) so record a real
      result, not SKIPPED.
- [ ] Q6 applied FIRST, before C1 can be verified: `ops/scripts/` is committed,
      because `COPY ops/scripts ops/scripts` is a second missing source. A build
      that only fixes the mainnet manifest still fails - this was proven by
      experiment, see section 7.1.
- [ ] Q6: the Dockerfile COPY-path guard test exists and fails when a COPY
      source is absent from the repository.
- [ ] Q6: `ops/README.md` no longer references deleted tooling, or the tooling
      is restored. Decide per file and record the decision.
- [ ] C2: NO CODE CHANGE. That item is retracted; implement codex R4's `/tmp`
      gate only. If a PROFILE-based guard was already written, remove it - it
      breaks the default rehearsal run, which uses the production profile.
- [ ] C3 applied: verification.md lists all FIVE rehearsal overrides
      (three CONFIRMATIONS, RPC_TIMEOUT_MS, LOG_RANGE) and, for each, whether
      the production value was exercised. `INDEX_REWIND_BLOCKS` is not an
      override and must not be listed as one.
- [ ] Q1: example env updated; §6a mentions send-path exposure. Base and
      Arbitrum send endpoints unchanged.
- [ ] Q2: preflight chainId assertion added and tested, or the accepted-risk
      decision written into design.md.
- [ ] Q3: `spokes.length >= 2`; rehearsal e2e still passes.
- [ ] Q4: owner decision recorded; Ethereum `crosschain` entry either added from
      a real manifest or explicitly recorded as blocked on phase 1-3;
      provider-list-length assertion added in the engine.
- [ ] Q5: `registry.ts` comment rewritten; cap decision recorded.
- [ ] Section 5 untouched: `git diff` shows no change there.
- [ ] `cd ops && npm test` fully green. The baseline recorded in section 7 is
      49 tests / 48 pass / 1 fail, and Q6.3 turns that last one green - do not
      carry the failure forward as "expected".
- [ ] `npx tsc --noEmit -p ops` exits 0. It already does; see section 7.4 for
      why the documented `node:sqlite` error must not be expected.
- [ ] `forge test --no-match-path 'test/forking/*'` passes 176/176; no file
      under `contracts/` changed.
- [ ] `forge test --match-path 'test/forking/*'` passes 49/50 with the single
      known-noise `NewVaultWithdraw.t.sol::testWithdrawTrace` failure, or 50/50
      if `VAULT` and `DEPLOYER_ADDR` are supplied. See section 7.3.
- [ ] `ops/rehearsal/run.sh` completes with `REHEARSAL PASSED`. It does today on
      this branch - section 7.2 records a full nine-step pass. Re-run it after
      your changes and do not regress it.
- [ ] `changes/ts-419-ethereum-crosschain-spoke/verification.md` updated, one
      line per item, with observed output.

## 5. Verified correct - do not change

Checked during review. Re-checking is wasted effort; changing these is a
regression.

- D1. `TransferIndex.sameDeploymentBeforeAddition` is correct, including a
  detail that looks like a bug and is not. `save()` writes
  `Object.fromEntries(this.sent)` where the map values are `TransferEvent`
  OBJECTS carrying `chainKey`, so `Object.values(raw.sent).some(e => !covered.includes(e.chainKey))`
  reads a real `chainKey` and behaves as written. It would silently always
  reject if `sent` were a map of arrays; it is not. `ops/test/snapshot.test.ts`
  covers a foreign agent on a covered chain, a chain outside the registry, the
  rewind clamp, resume-after-failure with checkpointed pages, and a read-only
  consumer being unable to overwrite scan progress.
- D2. The `Math.max(c.manifest.startBlock, ...)` clamp in `sync` fixes a real
  defect this branch's rehearsal found in runs 8 and 9, and is correctly scoped:
  the agent emits no events below `startBlock`, so nothing is missed.
- D3. `test/forking/CctpV2Adapter.t.sol` was STRENGTHENED, not weakened. It adds
  a real burn from Ethereum (domain 0) finalized by a Base adapter, and
  missing-MessageTransmitterV2 checks. Refactoring a shared test to gain
  coverage is the right direction here; do not simplify it back, and do not drop
  the fork-skip guards.
- D4. CCTP parameters are internally consistent. `minFinalityThreshold` is 2000
  on all three chains; TokenMessenger and MessageTransmitter are shared
  constants across base, arbitrum and mainnet; `ops/test/registry.test.ts`
  asserts chain ids and CCTP domains are unique. `confirmations` is 12 on
  mainnet against 10 base and 20 arbitrum, and per the registry comment it does
  not gate bridged funds, because the attestation waits for Ethereum finality
  regardless.
- D5. The Ethereum registry addresses are not transcribed by hand.
  `ops/test/registry.test.ts` asserts every reused provider equals the
  deployment record of that network. I ran that suite at `106e905`: 4 tests,
  4 pass, 0 fail.
- D6. `PROFILE` handling is the pattern to copy, not to fix: the value is
  validated at module load (`unknown CROSSCHAIN_PROFILE`) and
  `ops/src/preflight.ts` cross-checks it against the profile recorded in the
  manifest. C2 and Q2 both extend this existing pattern.
- D7. The documented service-rollout window in §6a is sound. "Too early is
  impossible / too late stops Ticks / in between is safe" correctly describes
  the interaction between the image build, `setChains` execution and NAV's
  `accountant tracks chains not configured here` failure. C1 removes the
  accidental half of that guarantee; the intentional ordering stays.

## 6. Evidence log

Read-only review. No branch was checked out and no tracked file was modified to
produce these findings.

```
git ls-tree -r --name-only <ref> -- deployments/mainnet/crosschain.json   # empty on main, 419 and 420
git show HEAD:ops/Dockerfile | grep -n COPY                                # line 19 is the mainnet manifest
git show HEAD:.dockerignore                                                # allowlist, three per-chain lines
git diff --quiet HEAD -- ops/Dockerfile .dockerignore                      # IDENTICAL
git ls-tree -r --name-only <ref> -- scripts/extract-errors.js              # MISSING on all three branches,
                                                                           # so the errors.json failure is pre-existing
node --test --require ts-node/register/transpile-only ops/test/registry.test.ts
                                                                           # 4 pass, 0 fail at 106e905
grep -n "RPC_" ops/.env.server.example                                     # 9 Moralis read, 12 publicnode send
grep -n "spokes.length" ops/rehearsal/e2e.ts                               # 76 hardcoded, 118/172/221 dynamic
grep -n "staticNetwork" ops/src/config.ts                                  # readRequest
grep -n "maxChainExposure" -B4 deploy/crosschain/registry.ts               # comment vs 0n
grep -n "REHEARSAL_NETWORKS\|CROSSCHAIN_PROFILE" -r . --include=*.ts --include=*.sh
                                                                           # run.sh 51, 129, 151, 227
sed -n '387,428p' contracts/Rebalancer.sol                                 # _withdraw tolerates a failed provider
grep -rn "readOnly\|L1 gas" Thesauros-Rebalance-Engine/libs/networks/src/deployments.ts
grep -n "crosschain" Thesauros-Rebalance-Engine/libs/networks/src/deployments.ts
                                                                           # entries at 93 and 216 only
```

Still not verified, stated as unverified:
- The ethers 6.16.0 `staticNetwork` behaviour in Q2 is taken from the pinned
  version in `ops/package.json` and the documented semantics of that option. It
  was not confirmed by an experiment against a wrong-chain RPC. If you implement
  the preflight assertion, that experiment becomes unnecessary.
- `TickAccountant.setChains` having no guard against removing a funded chain is
  codex R4's finding, quoted here for severity. It was not independently
  re-verified against the contract source during this review.
- Q1's mempool-exposure reasoning for `RPC_SEND_MAINNET` was not demonstrated
  empirically. It follows from the fact that the send path is a public endpoint,
  not from an observed front-run.

## 7. Reproduction log - actually executed, not quoted

Everything below was run on this branch (`cb54abb`, code identical to `106e905`)
in a dedicated worktree, so the results are observations rather than citations
from `verification.md`. Environment: macOS, forge 1.5.2, solc 0.8.33, ethers
6.16.0, Docker server 29.8.2, Node 22. RPCs were probed first and all three
answer archive queries two million blocks behind head, so no fork test was
skipped for lack of an archive node.

| Check | Command | Result |
|---|---|---|
| Docker image build | `docker build -f ops/Dockerfile .` | FAILED, exit 1 |
| forge build | `forge build` | OK, 128 files, 10.8s |
| forge non-fork | `forge test --no-match-path 'test/forking/*'` | 176 passed, 0 failed, 11 suites, 131.3s |
| forge forking, whole dir | `forge test --match-path 'test/forking/*'` | 49 passed, 1 failed, 50 total |
| forge forking, 419 targets | `--match-path .../CrossChainStrategyEthereum.t.sol` | 4 passed |
| forge forking, 419 targets | `--match-path .../CctpV2Adapter.t.sol` | 3 passed |
| ops unit tests | `cd ops && npm test` | 49 tests, 48 pass, 1 fail |
| ops type check | `npx tsc --noEmit -p ops` | exit 0, NO errors |
| full rehearsal | `ops/rehearsal/run.sh`, production profile | PASSED, exit 0 |

### 7.1 The docker build failure is confirmed, with the exact error

```
#13 [11/13] COPY deployments/mainnet/crosschain.json deployments/mainnet/crosschain.json
#13 ERROR: failed to calculate checksum of ref ...: "/deployments/mainnet/crosschain.json": not found
Dockerfile:19
ERROR: failed to build: failed to solve: failed to compute cache key
```

`deployments/base/` and `deployments/arbitrum/` COPY fine at steps 9 and 12;
only the mainnet one fails. `ls deployments/mainnet/` in this tree shows no
`crosschain.json`. This is R1 and it is not theoretical - the production ops
image cannot be built from this branch today.

There is a SECOND missing source that the build never reaches, because BuildKit
aborts on the first error. Checking every COPY source against the tree:

```
  OK      ops/package.json
  OK      ops/tsconfig.json
  OK      ops/src
  MISSING ops/scripts
  OK      deploy/crosschain/registry.ts
  OK      deployments/base/crosschain.json
  OK      deployments/arbitrum/crosschain.json
  MISSING deployments/mainnet/crosschain.json
```

Proven by rebuilding with only the mainnet line removed:

```
#11 [ 7/12] COPY ops/scripts ops/scripts
#11 ERROR: failed to calculate checksum of ref ...: "/ops/scripts": not found
ERROR: failed to build: failed to solve: failed to compute cache key
PROBE_RC=1
```

So fixing R1 alone does NOT yield a buildable image. `ops/scripts/` is absent
from the repository in `main`, in this branch and in 420; see Q6 for the root
cause (commit `0c420d3`) and the fix. Implement Q6 before attempting to verify
C1, otherwise the build will keep failing and the cause will look like C1 was
done wrong.

The C1 glob was validated separately with a throwaway context containing
`deployments/{base,arbitrum,mainnet,monad}/crosschain.json` plus a
`CompoundV3Provider.json` and a `solcInputs/` file. With
`!deployments/*/crosschain.json` and `COPY deployments deployments`, the built
image contained exactly the four `crosschain.json` files - the provider record
and `solcInputs` stayed out, and the hypothetical fifth chain was picked up with
no Dockerfile edit.

### 7.2 The rehearsal now passes end to end, which closes R9

This is the significant result. `verification.md` records that runs 10, 11 and
12 all failed before step 8 and that "steps 8, 8b and 9 have not completed with
Ethereum in the set yet". A full run on this branch completed all nine steps:

```
== 8. user redeems part through the queue and part instantly
  nav snapshot built  tickId 5  positions 3  inFlight 0  unhealthy []
  nav tick committed  tickId 5  status Accepted
  keeper clearRedeems / claim #2
  ✓ redemption cleared, funded and claimed by the keeper
== 8b. return path: arbitrum and mainnet strategies -> CCTP -> base -> vault
  deallocate + bridgeOut on arbitrum, relayer delivered
  deallocate + bridgeOut on mainnet, relayer delivered
  ✓ hub agent received exactly 10000 USDC back from each spoke
== 9. indexer + API
  ✓ indexer healthy and synced
  ✓ API vault summary at tick 7
  ✓ API user requests redeem:claimed, deposit:claimed
  ✓ API shows the instant exit
  ✓ API allocation shows capital on every chain
  ✓ API tick history (8 ticks)
  ✓ API shows the delivered CCTP transfer
REHEARSAL PASSED
REHEARSAL_EXIT=0
```

Every NAV snapshot in the run reports `positions: 3` and `unhealthy: []`, so the
Ethereum leg is counted in NAV and no provider was excluded. Run with the
default `production` profile and the real Safe impersonated, three anvil forks,
`ETHEREUM_FORK_URL` and `ARBITRUM_FORK_URL` pointed at the archive endpoints
from `.env`. Elapsed about 14 minutes. The three anvil processes were reaped by
the script's own EXIT trap.

Note for R9.2: this pass does NOT close the divergence gap. It ran with
`CONFIRMATIONS_BASE=1`, `CONFIRMATIONS_ARBITRUM=0`, `CONFIRMATIONS_MAINNET=0`,
`RPC_TIMEOUT_MS=180000` and `LOG_RANGE=2000`. Production uses 10/20/12, 15000
and 9000. See C3.

Also note: the run used `ethereum-rpc.publicnode.com` for the Ethereum fork, the
endpoint `verification.md` describes as serving "only the last ~100 blocks" and
blames for run 12's failure. Phase 1 on Ethereum and the whole e2e succeeded
against it, and a direct probe of a block two million behind head returned data.
That documented limitation did not reproduce. It may still be intermittent, so
do not delete the paid-RPC recommendation on the strength of one run - but the
claim as written is not currently accurate.

### 7.3 The single fork failure is a manual harness, not a regression

```
[FAIL: vm.envAddress: environment variable "VAULT" not found] testWithdrawTrace()
  test/forking/NewVaultWithdraw.t.sol
```

That file requires `VAULT` and `DEPLOYER_ADDR` and is an operator trace tool,
not an automated test. It is byte-identical on `main`, on this branch and on
`feat/ts-420-fluid-ethereum`, so neither branch touched it. It only appears when
the whole `test/forking/` directory is run; `verification.md` never saw it
because it uses `--match-path` on individual files. Treat it as known noise and
record it as such rather than chasing it.

### 7.4 Two documented baselines do not reproduce

- `npx tsc --noEmit -p ops` exits 0 with no output. Both `verification.md` files
  describe a "known `node:sqlite` type error on main". With the current
  `node_modules` it is absent. Do not treat a clean `tsc` as a new problem, and
  do not "restore" the error.
- `cd ops && npm test` gives 49 tests / 48 pass / 1 fail on this branch and
  50 / 49 / 1 on the 420 branch. The one failure is
  `src/errors.json matches the compiled artifacts`, failing with
  `Cannot find module '../scripts/extract-errors.js'` from
  `ops/test/abi.test.ts:46`. The required path is `ops/scripts/extract-errors.js`,
  which is absent from the repository in `main`, in this branch and in 420 - so
  the failure is pre-existing and is codex R8. Its root cause is Q6: commit
  `0c420d3` deleted the whole `ops/scripts/` directory. R8 and Q6.3 are the same
  fix, and it also unblocks `COPY ops/scripts` in the Dockerfile. A copy of
  `extract-errors.js` exists UNTRACKED on disk in the main worktree only; it is
  not in a fresh checkout, so a clean clone or CI runner reproduces the failure.
  Compare any on-disk copy against `git show bdb0c7d:ops/scripts/extract-errors.js`
  before committing it.
- The rehearsal's documented Ethereum RPC limitation did not reproduce either.
  `verification.md` says publicnode "serves only the last ~100 blocks on
  Ethereum" and blames it for run 12's failure. This run used
  `ethereum-rpc.publicnode.com` for the Ethereum fork and completed phase 1 on
  Ethereum plus all nine e2e steps. A direct probe of a block two million behind
  head returned full block data on all three endpoints. Treat the paid-RPC
  recommendation as still prudent, but the stated limitation is not currently
  accurate and should be re-worded rather than repeated.
