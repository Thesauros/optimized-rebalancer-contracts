# TS-420 review (Qwen): supplement to 420-rewiev_codex.md

You are fixing branch `feat/ts-420-fluid-ethereum` of
`Thesauros/optimized-rebalancer-contracts`. This file is a SUPPLEMENT, not a
replacement. `420-rewiev_codex.md` is the primary package for this branch; read
it first and execute its R1-R7. This file adds findings that review did not
cover, corrects two of its premises, and lists code you must not break.

Review basis: commits `df5b62b` (parent `106e905`) for the Fluid change, plus a
cross-repository read of `Thesauros-Rebalance-Engine` and
`thesauros-vault-data-service`. Line numbers refer to `df5b62b` and drift; locate
targets by symbol name with grep, not by line number alone.

Numbering: `Q*` items are mine, `R*` items are codex's.

## 0. Execution order

1. Apply `419-rewiev_codex.md` and `419-rewiev_qwen.md` on
   `feat/ts-419-crosschain-ethereum`, then rebase this branch (codex section 0).
2. Execute codex R1-R7 in order.
3. Then execute Q1-Q6 below. Q1 and Q2 are in a DIFFERENT repository
   (`Thesauros-Rebalance-Engine`) and are not blocked by anything in this one.
4. Run the combined verification in section 4.

Do not implement a Q item by weakening an R item. Where they touch the same
function (Q3 and R1 both concern `getDepositRate`), Q3 is the code change and R1
is the review gate; do both.

## 1. Ground rules

- Never push. Commit locally only, and only if the owner asks. If asked, verify
  `git rev-parse --abbrev-ref @{upstream}` is `origin/feat/ts-420-fluid-ethereum`
  first.
- Another agent works in this repository. Stage by path. Never `git add -A`.
  Run `git status --porcelain` before every commit and confirm you are adding
  only your own files.
- Do not change `Rebalancer.sol` or any already-deployed contract.
- Commits: `[ts-420-ethereum-fluid-provider] <summary>`, body, blank line,
  `Change: ts-420-ethereum-fluid-provider`, then your harness co-author trailer.
- No emojis anywhere in documentation or code comments.
- Never invent a value where real data is absent. If a check cannot run (no RPC,
  no archive node), record it as skipped with the reason in verification.md. Do
  not write a passing result you did not observe.

## 2. Corrections to the codex package

Read these before implementing R1 and R7. Both change the priority of a codex
item; neither cancels it.

### C1. R1's premise "the rate is not consumed on-chain or by ops (only by off-chain allocators, if any)" is wrong

`getDepositRate` IS consumed in production, by two services, in two other
repositories. Verified by grep, not inferred:

- `Thesauros-Rebalance-Engine/libs/pools/src/pool-multi.ts`
  - `depositRates()` multicalls `getDepositRate` over EVERY provider in the
    static list and returns the results positionally.
  - the caller computes the balance-weighted portfolio rate:
    ```ts
    const weightedBalances = balances.map((balance, index) => balance * depositRates[index]);
    const totalWeightedBalance = weightedBalances.reduce((t, b) => t + b, 0n);
    if (totalBalances > 0n) return totalWeightedBalance / totalBalances;
    ```
    This is the published APY of the vault.
  - fallback path when there are no balances yet: `entryProvider.contract.getDepositRate.staticCall(...)`.
- `thesauros-vault-data-service/libs/pools/src/pool.ts` - same shape, this is
  the retail-facing data API.

Consequence for R1: an incorrect Fluid rate is not a hypothetical allocator
input. It directly skews the APY shown to users, weighted by Fluid's share of
strategy assets. R1's independent review stays REQUIRED, and the reviewer's
scope must include the bit layout of the packed slot (already listed) with the
knowledge that a mis-decode surfaces as a wrong public number, not as a revert.

Consequence for R7: R7's conclusion (do not clamp `withdraw` to `maxWithdraw`)
is still correct. Its reasoning about the redemption path is also correct - see
section 3, D3.

### C2. A previous review of this branch mis-stated the withdrawal blast radius. The correct split is:

- Redemption path `Rebalancer._withdraw` (contracts/Rebalancer.sol, the loop over
  `$._providers`) TOLERATES a failing provider:
  ```solidity
  (bool success,) = address(provider)
      .delegatecall(abi.encodeWithSignature("withdraw(uint256,address)", amount, address(this)));
  if (success) { /* measure the delta */ }
  ```
  with the in-code comment "continue to next provider instead of reverting the
  entire tx." A shortfall across all providers ends in `InsufficientLiquidity`.
- Rebalance path `Rebalancer.rebalance` does NOT tolerate it. It calls
  `_delegateActionToProvider`, which ends in `address(provider).functionDelegateCall(data)`.
  A revert there propagates and fails the whole `rebalance` batch, including
  legs already conceptually planned. There is no per-leg isolation.
- Both paths hard-revert on a failing VIEW: `_safeGetDepositBalance` returning
  `ok == false` yields `revert ProviderUnavailable()` in `_withdraw`, and
  `revert InvalidProvider()` in `rebalance`.

So: a Fluid withdrawal-limit revert degrades gracefully on redemption and
blocks the entire rebalance batch on rebalancing. When you document behaviour
per R7, document both paths. When you write the R3 phase-1 guard, remember that
`rebalance` is the brittle one.

## 3. Q findings

### Q1. HIGH, REQUIRED (different repository): the Rebalance-Engine cannot represent a Fluid provider

The engine keeps a hand-transcribed deployment registry. `ProviderKindEnum`
(`Thesauros-Rebalance-Engine/libs/networks/src/interfaces.ts`) is closed:

```ts
export enum ProviderKindEnum {
  AaveV3 = 'AaveV3',
  CompoundV3 = 'CompoundV3',
  Morpho = 'Morpho',
}
```

and `createProvider` (`libs/pools/src/provider-factory.ts`) ends in:

```ts
default:
  throw new Error(`Unsupported provider kind "${deployment.kind}" on ${network}`);
```

There is no `Fluid`. Any attempt to record a FluidProvider in `deployments.ts`
either fails to type-check or throws at runtime in the pool service.

Also in `libs/networks/src/deployments.ts`:
- the file header states "Provider order matches the on-chain `getProviders()`
  order of each vault". `strategyProviders(entry, contracts)` in this branch's
  `deploy/crosschain/registry.ts` puts Fluid LAST (entry, fresh Compound, other
  reused, fresh Fluid). The engine transcription must match that order exactly.
- `crosschain` blocks exist only for two networks. There is NO `crosschain`
  entry for `[NetworkEnum.Ethereum]`, although `slug: 'mainnet'` is already set
  there and `getCrosschainDeployment` reads
  `join(dir, deployments[network].slug, 'crosschain.json')`, i.e. it expects
  `mainnet/crosschain.json`.

Why this is HIGH and not a future task: `pool-multi.ts` derives the published
APY from a POSITIONAL zip of `balances[]` and `depositRates[]`. A length or
order mismatch between the static list and on-chain `getProviders()` does not
throw. It silently pairs the wrong balance with the wrong rate and publishes a
wrong APY.

Required, in `Thesauros-Rebalance-Engine`:
1. `ProviderKindEnum.Fluid = 'Fluid'`.
2. A `FluidProvider` adapter class next to the existing ones, and
   `case ProviderKindEnum.Fluid: return new FluidProvider(deployment.address, network);`
   in `createProvider`.
3. The Ethereum `crosschain` entry, transcribed from the manifest phase 1
   produces. Do not write it from this registry file - transcribe from
   `deployments/mainnet/crosschain.json` once it exists, per the repo's own rule
   that the deployment record is authoritative.
4. A test that asserts the static provider list length equals the on-chain
   `getProviders()` length for every vault in the registry, and that the order
   matches. Without this assertion the same class of bug recurs on the next
   provider.

Sequencing: land 1-2 and 4 BEFORE the Ethereum cross-chain strategy is tracked
by the engine. Item 3 depends on a real deployment record and must not be
guessed.

### Q2. HIGH, REQUIRED (different repository): one reverting provider view takes down the whole published APY

`pool-multi.ts` uses `aggregate`, not `aggregate3`:

```ts
const aggregateResult = await multicalls[this.network].aggregate.staticCall(aggregateData, { blockTag: blockNumber });
return aggregateResult.returnData.map((data, index) => aggregateData[index].callBack(data));
```

`aggregate` reverts if ANY call reverts. `aggregate3` returns a per-call success
flag. So a single reverting `getDepositRate` or `getDepositBalance` fails the
entire multicall and the APY read for the whole vault, not just the Fluid
component.

This interacts directly with codex R2. `FluidProvider.getDepositRate` reads

```solidity
liquidity.readFromStorage(keccak256(abi.encode(_asset, EXCHANGE_PRICES_SLOT)))
```

where `liquidity` is an immutable captured in the constructor. Per codex R1's
on-chain facts, that Liquidity address is an upgradeable proxy. If a Fluid
upgrade ever leaves that address without code, `readFromStorage` reverts, and
through `aggregate` that kills the vault's entire published APY - a larger blast
radius than the Fluid position itself.

Required, in `Thesauros-Rebalance-Engine`: switch the provider multicalls in
`pool-multi.ts` to `aggregate3` and treat a failed leg as "rate unknown". Define
the unknown case explicitly rather than defaulting it to zero: a zero rate
silently drags the weighted average down and looks like a real yield collapse.
Emit a named condition (for example `rate_unavailable:<provider>`) and surface
it, per the no-fabricated-values rule.

Q3 below removes the revert source on the contract side. Do both: Q3 makes
Fluid safe, Q2 makes the engine safe against the NEXT provider that reverts.

### Q3. MEDIUM, REQUIRED: `getDepositRate` has no ceiling and no external boundary, unlike the convention in this repository

`MorphoV2Provider.getDepositRate` - same interface, same repository - is
defensive on all three axes:

```solidity
uint256 rateCap = uint256(morphoVault.maxRate()) * YEAR * WAD_TO_RAY;
try this.getAdapterRateContribution{gas: ADAPTER_RATE_CALL_GAS}(adapter, assets) returns (uint256 contribution) {
    rate += Math.min(contribution, rateCap - rate);   // "Saturate before adding"
} catch {}
```

with `ADAPTER_RATE_CALL_GAS = 3_000_000` and an external boundary function
documented as "External boundary for getDepositRate's bounded try/catch".

`FluidProvider.getDepositRate` has none of it: raw packed-slot read, unchecked
arithmetic, no ceiling, no try/catch. A mis-decoded field returns a plausible
wrong number instead of failing.

Required, in `contracts/providers/FluidProvider.sol`:

```solidity
/// An accrual ceiling. A decoded field outside it means the packing moved under
/// us: degrade to zero rather than rank a garbage rate first.
uint256 private constant MAX_SUPPLY_YIELD_1E12 = 1e12; // 100%
uint64 private constant RATE_CALL_GAS = 300_000;

function getDepositRate(IRebalancer) external view override returns (uint256 rate) {
    try this.readSupplyYield{gas: RATE_CALL_GAS}() returns (uint256 y) {
        if (y > MAX_SUPPLY_YIELD_1E12) return 0;
        rate = y * YIELD_TO_RAY;
    } catch {}
}

/// @dev External boundary for getDepositRate's bounded try/catch, mirroring
///      MorphoV2Provider.getAdapterRateContribution. A codeless or migrated
///      Liquidity layer must degrade this view, not revert it.
function readSupplyYield() external view returns (uint256) {
    uint256 w = liquidity.readFromStorage(keccak256(abi.encode(_asset, EXCHANGE_PRICES_SLOT)));
    return _supplyYield(w & 0xffff, (w >> 16) & 0x3fff, (w >> 30) & 0x3fff, (w >> 219) & 0x7fff, (w >> 234) & 0x7fff);
}
```

Notes:
- Degrading to 0 is the fail-safe DIRECTION here: `solveLinearAllocation` ranks
  by rate descending, so 0 ranks Fluid last. It does mean silent
  under-allocation, so pair it with the monitor alert codex R2.2 asks for.
- Keep `getDepositRate` non-reverting. Q2 explains why a revert is worse than a
  zero.
- `RATE_CALL_GAS` must exceed the cost of one `readFromStorage` plus the pure
  math. 300k is generous for a single SLOAD-path external call; measure on the
  fork and record the number in verification.md rather than trusting this one.
- Verify the change does not break `testRateIsTheAccrualOfTheSupplyExchangePrice`,
  which is the differential test pinning the bit layout to within 0.1% relative.

### Q4. MEDIUM, REQUIRED: the rate-anomaly gate does not protect a newly added provider

`Thesauros-Rebalance-Engine/apps/rebalancer/fork/replay/policies.ts` (S3,
mirroring `RiskGuard.evaluatePreOptimization`):

```ts
export function anomalyGate(input: RunInput, config: PathConfig): boolean[] {
  const window = input.recorded.filter(({ t }) => t < input.t && t > input.t - config.smaWindowSeconds);
  return input.spots.map((rate, i) => {
    if (window.length < config.minSamples) return false;
    const average = window.reduce((sum, { rates }) => sum + rates[i], 0n) / BigInt(window.length);
    if (average === 0n) return false;
    ...
  });
}
```

Three independent holes, all of which apply to Fluid on day one:
- `window.length < config.minSamples` (n >= 3): a brand-new provider has no
  recorded history, so it is never flagged for its first samples.
- `average === 0n` returns false.
- the in-code comment states "only spikes up are caught (a drop reaches 100% at
  most and the test is strict)". A garbage-HIGH rate is exactly the spike-up
  case, and it is precisely the case the gate cannot see while history is empty.

Combined with `solveLinearAllocation`, which sorts by rate descending and fills
to `cap`, a garbage-high Fluid rate during the warm-up window is unopposed
except by the allocation cap. On-chain that cap is `capsBps.Fluid = 3_000`;
the engine has its own `applyMaxProviderAllocationCap`. Confirm which one binds
and record the number in verification.md - do not assume they agree.

Required:
1. Q3's ceiling is the primary defence. Implement it.
2. Add an explicit warm-up rule for a provider with fewer than `minSamples`
   of history: either exclude it from allocation until history exists, or clamp
   it against the median of the established providers. Choose one, write the
   decision into `design.md` of the change, and test it. Silently trusting an
   unbacked rate is not an option.

### Q5. LOW, REQUIRED: precision ordering in `_supplyYield`

The return expression divides before the final multiplications:

```solidity
return borrowRate * ((1e4 * supplyShare * borrowShare) / 1e54) * (1e4 - fee);
```

The inner quotient lands near 1e4, so roughly 4-5 significant digits survive
into the product. Reordering to multiply before the single division keeps more
precision at no gas cost:

```solidity
return (borrowRate * 1e4 * supplyShare * borrowShare * (1e4 - fee)) / (1e54 * 1e4);
```

Before applying, recompute the overflow bound. Current peak intermediate is
about 1e62 against 2^256 ~= 1.16e77, and the reordered form raises it. Show the
arithmetic in a comment and in verification.md. If the reordered form does not
fit with margin, keep the current one and record why.

This is LOW because 1e-4 relative error does not change allocation ranking. Do
not spend effort here ahead of Q1-Q4.

### Q6. LOW, REQUIRED: supports codex R5 with a concrete shape

Codex R5 asks for vectors over the interest-free branches and offers a
`FluidRateLib` extraction. Take the library option. Reasons specific to this
branch:
- `_supplyYield` is `private pure` with no dependency on `fToken`, `liquidity`
  or `_asset`, so the extraction is mechanical and cannot change behaviour.
- It makes both branches of BOTH conditionals (`supplyRatio & 1`,
  `borrowRatio & 1`) testable without a fork, which is the only practical way
  to cover states the live market is not currently in.
- It keeps `getDepositRate` non-reverting as Q3 requires.

One additional vector beyond codex's list, because it is load-bearing for
revert-safety and not only for correctness: `supplyRatio == 1` must return 0.
That early return is what prevents a division by zero in
`(RAY * 1e4) / (supplyRatio >> 1)`. A test on it pins the invariant, so a future
refactor cannot reintroduce the divide-by-zero.

## 4. Verification (combined, runs after codex section 4)

- [ ] codex R1-R7 done, in order.
- [ ] Q1.1, Q1.2, Q1.4 landed in `Thesauros-Rebalance-Engine`; Q1.3 recorded as
      blocked on a real `deployments/mainnet/crosschain.json`, NOT guessed.
- [ ] Q2: `aggregate3` in `pool-multi.ts`, with an explicit named condition for
      an unavailable rate and a test that one reverting leg does not fail the
      whole read.
- [ ] Q3: `getDepositRate` bounded and non-reverting; measured `RATE_CALL_GAS`
      recorded; `testRateIsTheAccrualOfTheSupplyExchangePrice` still passes.
- [ ] Q4: warm-up rule chosen, documented in design.md, tested. Binding cap
      value recorded.
- [ ] Q5: applied with the overflow bound recomputed, or explicitly not applied
      with the reason recorded.
- [ ] Q6: `FluidRateLib` extracted, all vectors from codex R5 plus the
      `supplyRatio == 1` divide-by-zero vector.
- [ ] Q7.1: `RequestPacer.acquire` has a deadline and throws a diagnostic naming
      method, weight and queue depth.
- [ ] Q7.2: `semaphore()` acquisition has a deadline and warns with queue depth.
- [ ] Q7.3: the nested-limited-call invariant is asserted, not just documented.
- [ ] Q7.4: pacer defaults revisited; the rehearsal raises them and production
      values are justified per provider tier.
- [ ] Q7.5: every `.wait(` in `ops/src/` bounded, with a regression test that a
      never-resolving wait exits non-zero and does NOT resend.
- [ ] Q7.6: `RoutedProvider.sender` gets its own `FetchRequest` with a timeout.
- [ ] Q7 gate: `ops/rehearsal/run.sh` completes with `REHEARSAL PASSED` on this
      branch. It does NOT today - two runs stalled in step 6, see section 7.2.
      This is the blocking item for 420; do not merge without it.
- [ ] Section 5 items untouched: `git diff` shows no change to them.
- [ ] `forge build` clean on `FluidProvider.sol` and new test files.
- [ ] `forge test --no-match-path 'test/forking/*'` passes 176/176. It does
      today; see section 7. Do not set `FOUNDRY_AUTO_DETECT_REMAPPINGS=false` for
      forge - that is a hardhat-only variable and it breaks `@openzeppelin`
      resolution in `test/unit/SecurityRemediation.t.sol`.
- [ ] Fork tests still 6/6 and 4/4 on an archive RPC. They are today; all three
      `.env` endpoints answer archive queries two million blocks behind head.
- [ ] `cd ops && npm test`: the baseline is 50 tests / 49 pass / 1 fail, and the
      one failure is fixed by 419's Q6.3, not carried forward as expected.
- [ ] `npx tsc --noEmit -p ops` exits 0. It already does; the documented
      `node:sqlite` error does not reproduce, so do not expect it.
- [ ] `changes/ts-420-ethereum-fluid-provider/verification.md` updated, one line
      per item, with actual observed output.

## 5. Verified correct - do not change

These were checked during review. Re-checking them is wasted effort; changing
them is a regression.

- D1. The delegatecall wiring is sound. `_delegateActionToProvider` builds the
  selector `withdraw(uint256,address)` / `deposit(uint256,address)`, which
  matches `FluidProvider.withdraw(uint256, IRebalancer)` and
  `deposit(uint256, IRebalancer)` since `IRebalancer` encodes as `address`.
  `_checkVault` requiring `address(this) == address(vault)` correctly pins the
  delegatecall context, and `vault.asset() != _asset` pins the asset.
- D2. `_supplyYield` has no reachable division by zero and no overflow. The
  `borrowRate == 0 || borrowRatio == 1 || supplyRatio == 1` early return is
  load-bearing: `supplyRatio == 1` means `supplyRatio >> 1 == 0`, which is the
  divisor in `(RAY * 1e4) / (supplyRatio >> 1)`. Every other division has a
  constant or `1e4 + x` denominator. Peak intermediate ~1e62.
- D3. `_withdraw`'s per-provider tolerance is intentional and correct. See C2.
  Do not "harden" it into a revert.
- D4. The constructor's validation chain is correct and should stay: `code.length`
  on the fToken, `_asset = fToken.asset()` with a `code.length` check, then
  `getData()` to obtain and validate `liquidity`. This is what rejects a generic
  ERC4626 before any approval could be granted to it. The test's note that
  `makeAddr("eoa")` carries an EIP-7702 delegation on mainnet is accurate and
  worth keeping.
- D5. `strategyProviders` ordering is consistent across all four consumers
  (`01-deploy.ts`, `02-configure.ts`, `05-governance-plan.ts`,
  `ops/src/checks/deployment.ts`) and is covered by the ops registry test
  asserting every label is listed once per network.
- D6. `setProviderCap` rejects an unregistered provider via `_validateProvider`,
  so a cap aimed at a provider the strategy does not have cannot silently apply.
  This is why codex R3's phase-1 guard fails loudly rather than corrupting state.
- D7. `setProviders(IProvider[] memory)` exists and is `onlyTimelock`
  (contracts/Rebalancer.sol). Codex's out-of-scope note is factually correct.
  What is missing is tooling, which is codex R3's OPTIONAL follow-up - and note
  that `grep -rn "setProviders" deploy/ ops/` returns nothing today.

## 6. Evidence log

Commands run during this review, so you can re-verify instead of trusting the
text. All read-only; no branch was checked out and no file was modified.

```
git ls-tree -r --name-only <ref> -- deployments/mainnet/crosschain.json   # empty on main, 419, 420
git show HEAD:ops/Dockerfile | grep -n COPY                                # line 19 is the mainnet manifest
git show HEAD:.dockerignore                                                # allowlist, three per-chain lines
git diff --quiet HEAD -- ops/Dockerfile .dockerignore                      # IDENTICAL, working tree clean
grep -rn "setProviders" contracts/                                         # Rebalancer.sol:638 onlyTimelock
grep -rn "setProviders" deploy/ ops/                                       # no results
grep -rn "getDepositRate" ops/src/ deploy/crosschain/                      # no results (ops does not read rates)
grep -rn "getDepositRate" Thesauros-Rebalance-Engine/libs thesauros-vault-data-service/libs
                                                                           # pool-multi.ts, pool.ts DO read it
grep -n "enum ProviderKindEnum" -A 12 Thesauros-Rebalance-Engine/libs/networks/src/interfaces.ts
                                                                           # AaveV3, CompoundV3, Morpho only
sed -n '25,60p' Thesauros-Rebalance-Engine/libs/pools/src/provider-factory.ts
                                                                           # default: throw Unsupported provider kind
sed -n '130,170p' Thesauros-Rebalance-Engine/libs/pools/src/pool-multi.ts  # aggregate, weighted APR
sed -n '85,130p' Thesauros-Rebalance-Engine/apps/rebalancer/fork/replay/policies.ts
                                                                           # anomalyGate holes, solveLinearAllocation
sed -n '387,428p' contracts/Rebalancer.sol                                 # _withdraw tolerates a failed provider
git log --all --oneline -- 419-rewiev_codex.md                             # f46c8bf on the 419 branch
```

Still not verified, stated as unverified:
- Fluid's `LiquidityCalcs.calcExchangePrices` source was not read. The bit
  layout is validated transitively by the existing differential fork test, not
  independently confirmed here. Codex R1 assigns that confirmation to the
  independent reviewer.
- The Q3 `RATE_CALL_GAS` figure of 300000 is a starting estimate, not a
  measurement. Measure it.
- Q4's claim about which cap binds (on-chain `capsBps.Fluid = 3000` versus the
  engine's `applyMaxProviderAllocationCap`) was not resolved. Determine it and
  record the number.

## 7. Reproduction log - actually executed, not quoted

Run on this branch (`df5b62b` code) in a dedicated detached worktree.
Environment: macOS, forge 1.5.2, solc 0.8.33, ethers 6.16.0, Docker server
29.8.2, Node 22. All three RPC endpoints were probed first and answer archive
queries two million blocks behind head.

| Check | Command | Result |
|---|---|---|
| Docker image build | `docker build -f ops/Dockerfile .` | FAILED, exit 1, `Dockerfile:19` |
| forge build | `forge build` | OK, 131 files (419 has 128; the 3 are FluidProvider, IFluid, FluidProvider.t.sol) |
| forge non-fork | `forge test --no-match-path 'test/forking/*'` | 176 passed, 0 failed |
| forge fork | `--match-path .../FluidProvider.t.sol` | 6 passed, 0 failed |
| forge fork | `--match-path .../CrossChainStrategyEthereum.t.sol` | 4 passed, 0 failed |
| ops unit tests | `cd ops && npm test` | 50 tests, 49 pass, 1 fail |
| ops type check | `npx tsc --noEmit -p ops` | exit 0, NO errors |
| full rehearsal, run 1 | `ops/rehearsal/run.sh`, production profile | STALLED at step 6 after a successful mainnet allocate, 18+ min, killed |
| full rehearsal, run 2 | same command, repeat | STALLED at step 6 before reaching mainnet allocate, 11.5 min, killed |

The fork results reproduce `verification.md` exactly: FluidProvider 6/6 and
CrossChainStrategyEthereum 4/4, including
`testRateIsTheAccrualOfTheSupplyExchangePrice` (3.33s) and
`testActionsOnlyThroughTheVault`. The ops and tsc baselines match 419's; see
`419-rewiev_qwen.md` sections 7.3 and 7.4 for why the single ops failure and the
absent `node:sqlite` error are both explained by commit `0c420d3` (that file's
Q6), and note the Docker build has a SECOND missing source, `ops/scripts`, which
R1's fix alone does not address.

### 7.1 The rehearsal reaches Fluid on Ethereum and the deploy path works

Phases 1 to 5 completed on all three chains with Fluid present. From the log:

```
Ethereum (spoke, chainId 1)
  FluidProvider          0x4a80a1e53c776C93B84E0D1f790cd173637857bB
  Strategy.setProviderCap(Fluid, 3000)
  [mainnet] strategy cap Fluid (3000 bps)
phase 5: every chain now matches the registry
```

So `01-deploy.ts`, `02-configure.ts`, `05-governance-plan.ts` and
`checks/deployment.ts` all behave correctly with Fluid added, on a fresh
deployment. That is the part of codex's "the rehearsal was not re-run" concern
which is now discharged for the deploy path. It is NOT discharged for the e2e
cycle, which is what 7.2 covers.

### 7.2 The rehearsal stalls at step 6, and the cause is a hung `tx.wait()`, not the chain

At `== 6. relayer delivers on every spoke`, the mainnet leg printed:

```
--- exec allocate mainnet all --yes
allocate 50000.0 USDC on mainnet
  sent allocate: 0xc6098d4942cb87a81f8f8142b9d2e2aa5af760ff6ffe59bda480d16a911d1b97
```

and then produced no further output for over 18 minutes. The identical step on
the 419 branch completed normally:

```
  sent allocate: 0xbad617d087c07b877dce2a85a63f1513b3805651a2e92f03230e43353a52a6c4
  confirmed in block 26361709
  ✓ mainnet strategy shares held by the agent
```

The transaction is NOT the problem. Queried directly against the local Ethereum
fork at `127.0.0.1:8547` while the CLI was hung:

```
eth_getTransactionReceipt(0xc6098d...) ->
  {"status":"0x1","cumulativeGasUsed":"0x136fa3","logs":[{"address":"0xa0b8...eb48", ...
txpool_status -> {"pending":"0x0","queued":"0x0"}
eth_blockNumber -> 0x1924d38      (responds instantly)
```

`status: 0x1` is success and `0x136fa3` is 1,273,763 gas, with USDC transfer
logs. The allocation including Fluid executed correctly on chain. The pool is
empty. The fork answers immediately.

The hang is in the CLI. `ops/src/exec.ts`:

```
108:  console.log(`  sent ${label}: ${tx.hash}`);
109:  const r = await tx.wait();
111:  console.log(`  confirmed in block ${r.blockNumber}`);
```

It is blocked at line 109 with the receipt already available. Corroborating
observations taken while it hung:

- all three anvil processes at 0.0% CPU, with identical cumulative CPU time
  across two samples 20 seconds apart - the forks are idle, not working;
- the Ethereum anvil has no outbound TCP connection, only its LISTEN socket and
  two localhost connections from the ethers providers;
- the node process is in state `S` with 1.20s cumulative CPU after 17:34
  elapsed - it is blocked on I/O, not computing;
- `RPC_TIMEOUT_MS=180000` was in effect, so roughly six timeout periods elapsed
  without recovery;
- host memory was 48% free, so this is not memory pressure.

What is established and what is not. Established: `await tx.wait()` did not
resolve for over 18 minutes despite a mined, successful, retrievable receipt,
and a SECOND run stalled at a different point in step 6 for 11.5 minutes with no
`exec.ts` process running at all. The same step on 419 resolves normally. The
only difference at that step is that the mainnet strategy now has five providers
including Fluid. NOT established: the mechanism. Q7 below narrows it to the
local rate limiter with code evidence, but does not prove which of two candidate
mechanisms fired. Do not write a fix that assumes a specific cause without
instrumenting it.

### Q7. HIGH, REQUIRED: ops RPC calls can block forever in the local rate limiter, and nothing bounds them

This replaced an earlier, narrower version of this item that blamed `tx.wait()`
alone. Two rehearsal runs stalled at DIFFERENT points, which rules out a single
call site and points at shared infrastructure. Both runs are described below,
then the code that explains them.

Run 1 stalled at step 6, `exec allocate mainnet all --yes`, for over 18 minutes
after printing `sent allocate: 0xc6098d...`. The transaction had already
succeeded (section 7.2). The process was blocked at `ops/src/exec.ts:109`,
`const r = await tx.wait();`.

Run 2 stalled at step 6 as well, but EARLIER and in a different process: after
the base to arbitrum delivery, before `exec allocate mainnet` was ever reached.
It sat for 11.5 minutes with no `exec.ts` process running at all. The blocked
process was `e2e.ts` itself: state `S`, 1.22s cumulative CPU after 9:18 elapsed.

Common to both runs, measured while they hung:

- all three anvil forks alive and answering `eth_blockNumber` instantly;
- the upstream `ethereum-rpc.publicnode.com` answering in 2.4s;
- the Ethereum anvil holding NO outbound TCP connection, only its LISTEN socket
  and two localhost sockets from the ethers providers;
- the node process in state `S` with roughly 1 second of CPU after many minutes;
- host memory 48% free;
- `RPC_TIMEOUT_MS=180000` in effect, and no timeout ever firing.

No outbound connection plus a responsive upstream plus a blocked process means
**no HTTP request was in flight**. The code was waiting on something local.

#### The local rate limiter, and why RPC_TIMEOUT_MS cannot bound it

`ops/src/config.ts`:

```
71: const readGate = semaphore(4);
72: const readPacer = new RequestPacer(Number(process.env.RPC_REQUESTS_PER_SECOND ?? 10));
73: const computePacer = new RequestPacer(Number(process.env.RPC_COMPUTE_UNITS_PER_SECOND ?? 24));
78:   request.timeout = Number(process.env.RPC_TIMEOUT_MS ?? 15_000);
83:   request.preflightFunc = async (req) => {
84:     await computePacer.acquire(calls.reduce((sum, p) => sum + rpcWeight(p.method, p.params), 0));
85:     await readPacer.acquire();
94:   return retryTransient(() => readGate(() => super._send(payload)), 3, 1_000);
```

`request.timeout` bounds the fetch. `preflightFunc` runs BEFORE the fetch and
awaits two pacers. **Waiting for a pacer slot is therefore outside the
timeout's scope entirely.** The same is true of `readGate`: only four reads may
be in flight process-wide, and each holds a slot while it waits on the pacers.

`ops/src/rpc-pacer.ts` has no deadline on `acquire`:

```ts
acquire(weight = 1): Promise<void> {
  this.tail = this.tail.then(async () => {
    const delay = this.next - performance.now();
    if (delay > 0) await new Promise<void>((resolve) => setTimeout(resolve, Math.ceil(delay)));
    this.next = performance.now() + 1000 * weight / this.rate;
  });
  return this.tail;
}
```

It is a single strictly serialized queue. With `rate = 24` and the weights in
`rpcWeight`, one `eth_call` or `eth_getStorageAt` at a pinned (non-latest) block
costs 12 CU, which reserves `1000 * 12 / 24` = **500 ms of exclusive queue
time**. The default for an unknown method is also 12 CU. `eth_getTransactionReceipt`
is 8 CU = 333 ms.

NAV and the executor read at pinned reference blocks, so they pay the 12 CU
price, not the 3 CU latest price. Every such call serializes behind every other
one in the process at half a second each.

`ops/src/util.ts:26-30` documents the second hazard explicitly:

```
 * The slot is handed directly to the next waiter instead of being released and re-taken, so the
 * count stays exact under contention. Callers must not await a limited call from inside another
 * limited call: with every slot held by an outer call waiting on an inner one, that deadlocks.
```

With `readGate = semaphore(4)` and every provider read routed through it at
line 94, that invariant is load-bearing for the whole ops stack.

Neither `run.sh` nor `.env.server.example` raises these values: the example sets
`RPC_REQUESTS_PER_SECOND=10` and `RPC_COMPUTE_UNITS_PER_SECOND=24` for
production, and `run.sh` exports neither, so the rehearsal inherits the same
defaults. Those numbers are Moralis standard-plan budgets. They are being
applied to a local anvil fork that has no such budget, and to whichever
production provider is actually configured.

What is proven and what is not. PROVEN: the stalls are local, not network; the
pacer and the semaphore have no deadline; `RPC_TIMEOUT_MS` cannot bound either;
420 raises the Ethereum provider count from 4 to 5, which raises the pinned-block
call count per cycle; 419 completed the identical step. NOT PROVEN: which of the
two mechanisms (unbounded pacer queueing versus the documented nested-acquire
deadlock) produced each stall. Do not claim a mechanism in a commit message
without instrumenting it.

Required:
1. Put a deadline on `RequestPacer.acquire`. Reject after a bounded wait so a
   stall becomes an error the retry layer and the operator can see, instead of a
   silent hang:
   ```ts
   acquire(weight = 1, deadlineMs = Number(process.env.RPC_PACER_DEADLINE_MS ?? 30_000)): Promise<void>
   ```
   and throw a message naming the method, the weight and the queue depth.
2. Put a deadline on `semaphore()` acquisition, and log a warning with the queue
   depth when all slots have been held longer than a threshold. That converts
   the documented deadlock from an infinite hang into a diagnosable event.
3. Assert the nesting invariant instead of only documenting it. A debug counter
   that throws when a limited call is awaited inside another limited call would
   have caught this at the first occurrence.
4. Re-examine the defaults. 24 CU/s against a local fork is pure self-throttling.
   Let the rehearsal raise `RPC_COMPUTE_UNITS_PER_SECOND` and
   `RPC_REQUESTS_PER_SECOND`, and set production values per provider tier rather
   than assuming Moralis standard.
5. Bound `await tx.wait()` at `ops/src/exec.ts:109` and at line 244 anyway, and
   grep `ops/src/` for every other `.wait(`. On timeout the command must print
   the hash, exit non-zero, and NOT resend:
   ```ts
   const r = await Promise.race([
     tx.wait(),
     new Promise<null>((resolve) => setTimeout(() => resolve(null), CONFIRM_DEADLINE_MS)),
   ]);
   if (!r) {
     console.error(`  NOT CONFIRMED within ${CONFIRM_DEADLINE_MS}ms. tx ${tx.hash} may still land.`);
     console.error(`  Check it with: cast receipt ${tx.hash} --rpc-url <send url>`);
     process.exitCode = 1;
     return;
   }
   ```
   This is independently necessary: `ops/src/exec.ts` is the operator CLI for
   bridge, allocate and deallocate. A silent hang after `sent <hash>` invites a
   re-run, and a re-run sends a SECOND transaction - a duplicate CCTP burn for a
   bridge, a double allocation for an allocate.
6. Note the related asymmetry while you are in `config.ts`. Line 102 builds the
   read provider from `readRequest(readUrl)`, but line 103 builds
   `this.sender = new JsonRpcProvider(sendUrl, ...)` from a bare URL string. The
   sender therefore gets NO `request.timeout`, NO `retryFunc = async () => false`
   override, and no pacers - it keeps ethers' default retry behaviour, which is
   exactly what the comment at line 79 says "can block for minutes". Sends should
   be rate limited differently from reads, but they should not be unbounded.
   Give the sender its own `FetchRequest` with a timeout.

Q7 is not specific to Fluid. It is a latent defect in the ops RPC layer that the
fifth Ethereum provider made reachable. Fixing it protects every chain and every
service, and it is the difference between a slow cycle and an operator staring
at a hung CLI with a live transaction in flight.
