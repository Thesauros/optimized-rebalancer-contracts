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

### C2. Refines R4: gate the registry narrowing on PROFILE as well as on the manifest dir

Codex R4 proposes refusing `REHEARSAL_NETWORKS` unless
`CROSSCHAIN_MANIFEST_DIR` starts with `/tmp/`. That works, but the `/tmp` test
is satisfiable by accident - an operator who stages manifests under `/tmp` for
any reason re-arms the footgun. Add a second, independent condition on the
profile, which the rehearsal can never satisfy:

```ts
if (only && PROFILE === 'production') {
  throw new Error('REHEARSAL_NETWORKS must not narrow the registry under CROSSCHAIN_PROFILE=production');
}
```

`PROFILE` is already validated two lines above its declaration in
`deploy/crosschain/registry.ts` (`unknown CROSSCHAIN_PROFILE`), so this follows
an existing pattern rather than inventing one.

Safety of the combined guard, verified against `ops/rehearsal/run.sh`:
- the rehearsal exports `CROSSCHAIN_PROFILE=stand` (the `PROFILE=rehearsal`
  branch maps to `stand`), so the PROFILE guard never fires there;
- `REHEARSAL_NETWORKS=base,arbitrum` is exported at line ~129 and unset at
  line ~151;
- the one place the rehearsal runs under `CROSSCHAIN_PROFILE=production`
  (line ~227, the phase 5 plan check on `baseLocal`) executes AFTER the unset,
  so `only` is empty and the guard cannot fire.

Keep codex's `/tmp` condition too. Two independent conditions, either of which
blocks the narrowing, is the right shape for a control whose failure mode is a
`setChains` batch that drops a funded chain.

Restating codex R4's severity because it is the sharpest consequence in either
package: a narrowed registry makes phase 5 on the hub plan `setChains` WITHOUT
Ethereum, and `TickAccountant.setChains` has no guard against removing a funded
chain. Executed through the Timelock, NAV drops by the whole Ethereum share.
This is a fund-accounting failure reachable from one stray environment
variable, gated only by the Safe and the delay.

### C3. Extends R9.2: there are three rehearsal-only overrides, not one

Codex R9.2 correctly identifies that the rehearsal exports
`CONFIRMATIONS_MAINNET=0` while production uses 12, so the rehearsed NAV path is
not the production one. The same run.sh exports two more:

- `RPC_TIMEOUT_MS=600000` against the production default of 15000;
- `INDEX_REWIND_BLOCKS=5000`.

All three are the same class of divergence: the rehearsal passes with values
production never uses. Extend R9.2 so verification.md records, for EACH override,
whether the production value was separately exercised - not only for
confirmations. Where it was not, record it as a gap, not as a pass.

Related and worth folding into R7: `RPC_TIMEOUT_MS` has no upper bound and no
validation. `envNumber` already treats an empty string as unset, which is what
codex R7 uses to fix the zero-timeout bug. Consider bounding the production
value while you are in that function - a leaked `600000` lets one hung RPC stall
the tick loop for ten minutes. If you bound it, exempt the rehearsal by profile
rather than by a magic number, and confirm `run.sh` still passes.

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
live chains and per-provider caps on Ethereum summing to 150 percent
(`CompoundV3` 5000, `GauntletPrimeMorpho` 4000, `SmokehouseMorpho` 3000,
`Fluid` 3000, entry uncapped), there is currently no on-chain ceiling on how
much of the vault can sit on one chain.

Required, minimally: rewrite the comment so it states the current decision and
points at §6a, instead of promising an action that was declined. Whether to set
a real value is the owner's call and should be recorded as an accepted risk if
it stays at 0.

## 4. Verification (combined, runs after codex section 3)

- [ ] codex R1-R7 implemented with tests; R8 decided; R9 run and recorded.
- [ ] C1 applied: `.dockerignore` uses `!deployments/*/crosschain.json`;
      `docker build -f ops/Dockerfile .` succeeds with NO mainnet manifest
      present, and the image's `deployments/` contains only `crosschain.json`
      files. If Docker is unavailable, record SKIPPED with the reason.
- [ ] C2 applied: both conditions present; a test that `REHEARSAL_NETWORKS`
      with `CROSSCHAIN_PROFILE=production` throws regardless of the manifest
      dir; `ops/rehearsal/run.sh` still completes.
- [ ] C3 applied: verification.md lists all three rehearsal overrides and, for
      each, whether the production value was exercised.
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
- [ ] `cd ops && npm test` at the documented baseline; `npx tsc --noEmit -p ops`
      shows only the `node:sqlite` error.
- [ ] `forge test --no-match-path 'test/forking/*'` passes; no file under
      `contracts/` changed.
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

Not verified, stated as unverified:
- No `docker build` was run. The build failure is deduced from Docker `COPY`
  semantics against a source path proven absent from the committed tree. C1's
  `docker run ... ls -R deployments` check is the way to confirm the fix.
- No forge test, fork test or rehearsal was run by this review. The 176/176,
  3/3 and 4/4 figures are quoted from
  `changes/ts-419-ethereum-crosschain-spoke/verification.md`, not reproduced.
- The ethers 6.16.0 `staticNetwork` behaviour in Q2 is taken from the pinned
  version in `ops/package.json` and the documented semantics of that option. It
  was not confirmed by an experiment against a wrong-chain RPC. If you implement
  the preflight assertion, that experiment becomes unnecessary.
- `TickAccountant.setChains` having no guard against removing a funded chain is
  codex R4's finding, quoted here for severity. It was not independently
  re-verified against the contract source during this review.
