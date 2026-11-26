# TS-420 review: fix package for the implementing agent

You are fixing branch `feat/ts-420-fluid-ethereum` of
`Thesauros/optimized-rebalancer-contracts`. It sits on top of TS-419
(`feat/ts-419-crosschain-ethereum`). The findings below come from a code review
of commit `df5b62b` (parent `106e905`). Line numbers refer to `df5b62b`.
Implement every item marked REQUIRED, in order, then run the verification
section. Items marked OPTIONAL may be deferred. Do not invent extra scope.

## 0. Prerequisite

1. Apply `419-rewiev_codex.md` on `feat/ts-419-crosschain-ethereum` first (that
   file is on that branch). Its R2 is a precondition for running Fluid safely
   (see R2 below).
2. Then rebase this branch onto it:
   `git rebase feat/ts-419-crosschain-ethereum`. Expected conflicts:
   - `ops/src/checks/deployment.ts`: 419-R1 changes the peer and chain-set loops
     (lines ~118 and ~166), this branch changed the provider list block (~139-150).
     The regions are disjoint; keep both.
   - `docs/crosschain-deployment.md`: keep both texts.

## 1. Context you need

- TS-420 adds Fluid lending (fUSDC) to the Ethereum strategy of the cross-chain
  vault. New contract `contracts/providers/FluidProvider.sol` with interfaces in
  `contracts/interfaces/fluid/IFluid.sol`.
- Providers implement `IProvider` and are **delegatecalled** by `Rebalancer`
  (`deposit`, `withdraw`), so they run in the strategy's storage and balance
  context. Views (`getDepositBalance`, `getDepositRate`, `getSource`) are
  external calls with a 3 M gas stipend (`PROVIDER_VIEW_CALL_GAS`).
- The Rebalancer fails closed: if any provider's `getDepositBalance` reverts,
  `totalAssets()` reverts `ProviderUnavailable`, which blocks deposits, exits and
  `convertToAssets` (`contracts/Rebalancer.sol:191, 326, 399, 928`).
- Registry: `deploy/crosschain/registry.ts`. `mainnet.strategy.fluidFToken` is
  `0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33`, cap `Fluid: 3_000` bps.
  `strategyProviders(entry, contracts)` (line 389) is the single source of
  provider order and labels for phases 1, 2, 4 and 5 (entry, fresh Compound,
  other reused, fresh Fluid).
- On-chain facts (2026-11-05):
  - fUSDC is immutable (no proxy). Its Liquidity layer
    `0x52Aa899454998Be5b000Ad077a46Bbe360F4e497` is an upgradeable proxy:
    EIP-1967 implementation slot set, `getAdmin()` = `0x2386DC45AdDed673317eF068992F19421B481F4c`.
  - Withdrawal limit: expand 50% over 21 600 s; withdrawable 22.0 M USDC
    (the layer's idle USDC).
  - Fluid rewards are inactive.

## 2. Ground rules

- Never push to `main`; push only if the owner asks. Check
  `git rev-parse --abbrev-ref @{upstream}` = `origin/feat/ts-420-fluid-ethereum`
  before pushing.
- Another agent may work in the same repository. Stage by path; never `git add -A`.
- Commits: `[ts-420-ethereum-fluid-provider] <summary>`, a body, a blank line,
  `Change: ts-420-ethereum-fluid-provider`, then your harness's co-author trailer.
- Record results in `changes/ts-420-ethereum-fluid-provider/verification.md`;
  record design changes in `design.md` of the same change.
- Tests:
  - `forge test --no-match-path 'test/forking/*'`.
  - Fork tests:
    `ETHEREUM_RPC_URL=<archive RPC> forge test --match-path test/forking/FluidProvider.t.sol`
    and `.../CrossChainStrategyEthereum.t.sol`.
    `publicnode` stalls; `https://eth.drpc.org` works but the free plan times out.
    Do not use `makeAddr("eoa")` as a codeless address: it has an EIP-7702
    delegation on mainnet.
  - `FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile && (cd ops && npm test)`.
- Do not change `Rebalancer.sol` or any deployed contract.

## 3. Findings and required changes

### R1. HIGH, REQUIRED (process): `FluidProvider` needs an independent review before mainnet funds

It is the first new provider contract in this series, unaudited, and runs by
delegatecall in the strategy context. The author found no defect. Prepare the
review, do not self-certify: write
`changes/ts-420-ethereum-fluid-provider/review-request.md` listing what the
reviewer must confirm:
- no storage writes; only immutables (`fToken`, `liquidity`, `_asset`);
- `_checkVault` (line ~50): delegatecall-only context and asset match on
  `deposit` and `withdraw`;
- `deposit`/`withdraw` call the fToken's 2-/3-argument ERC4626 overloads;
  allowance is granted by the Rebalancer to `getSource()` = the immutable fToken;
- the constructor rejects a codeless address, a generic ERC4626 (no `getData()`)
  and a codeless Liquidity address;
- `getDepositBalance` = `previewRedeem(balanceOf(user))`;
- `getDepositRate` (line ~67) and `_supplyYield` (line ~76) match Fluid's
  `LiquidityCalcs.calcExchangePrices`: slot `keccak256(abi.encode(asset, 5))`,
  bit layout of `exchangePricesAndConfig`, ratio semantics;
- overflow bounds: max intermediate ≈ 1e62 < 2^256. `1e4 - fee` underflows only
  if Fluid stored fee > 1e4, which Fluid validation forbids. The rate is not
  consumed on-chain or by ops (only by off-chain allocators, if any).
Do not deploy `FluidProvider` until the reviewer signs off; note that in the
runbook's §6a.

### R2. HIGH, REQUIRED: a Fluid failure freezes the whole Ethereum strategy, and (until 419-R2 lands) every Tick

- If `fToken.previewRedeem`/`balanceOf` revert (e.g. after a Liquidity upgrade),
  `Rebalancer.totalAssets()` reverts. Deposits and all exits of the Ethereum
  strategy revert, not only the Fluid share. A funded provider cannot be removed.
  The 30% cap does not narrow this.
- Without 419-R2, NAV's `convertToAssets` call reverts as well and no Tick is
  committed for any chain.

Required:
1. Confirm 419-R2 is merged into this branch (rebase, section 0).
2. OPTIONAL but recommended, monitor: alert on Fluid Liquidity upgrades.
   - Before coding, read the verified source of
     `0x52Aa899454998Be5b000Ad077a46Bbe360F4e497` on Etherscan. It is Fluid's
     proxy with an admin and implementations per function signature. Find the
     events emitted when the admin, the dummy implementation, or any
     implementation/signature mapping changes. Use the exact names from the
     source, not guesses.
   - In `ops/src/monitor.ts`, when the Ethereum manifest contains
     `FluidProvider`, scan those events from the manifest `startBlock` with the
     existing `EventCache` (`ops/src/util.ts`). Report `warn` with
     `"Fluid Liquidity changed at block N: re-run test/forking/FluidProvider.t.sol before the next allocation"`.
   - Unit-test the check with a fake contract/event list.
3. Runbook (§6a, Fluid paragraph): state the blast radius above and the operator
   action on a `strategy.mainnet.health` crit (pause new allocations to Ethereum;
   Fluid's own status first).

### R3. MEDIUM, REQUIRED: Fluid must be in the provider list when the Ethereum strategy is initialized; fail loudly otherwise

Phase 1 (`deploy/crosschain/01-deploy.ts:125-128`) deploys `FluidProvider` but
adds providers only when it creates the Strategy. On a Strategy initialized
without Fluid (TS-419 deployed alone), it silently leaves Fluid out. Phase 5
plans caps only, not `setProviders`. Phase 4 then reports `strategy providers`
mismatch forever.

Required, in `01-deploy.ts` right after `const providers = ...` (line 126):
```ts
if (m.contracts.Strategy) {
  const onChain: string[] = await (await ethers.getContractAt('Rebalancer', m.contracts.Strategy, signer)).getProviders();
  const missing = providers.filter((p) => !onChain.some((o) => o.toLowerCase() === p.toLowerCase()));
  if (missing.length) {
    throw new Error(
      `Strategy ${m.contracts.Strategy} was initialized without ${missing.join(', ')}: phase 1 cannot add providers; ` +
        'queue a Timelock setProviders with the full list (strategyProviders in registry.ts), see docs/crosschain-deployment.md §6a',
    );
  }
}
```
OPTIONAL follow-up, only if the owner wants TS-419 deployed before TS-420:
- make phase 5 (`deploy/crosschain/05-governance-plan.ts`, cap block at line
  ~84) plan `setProviders(strategyProviders(entry, c))` in the Timelock batch when
  the on-chain list is a strict subset of the registry list (additions only;
  throw on any removal);
- emit the caps of newly added providers in the Timelock batch after
  `setProviders`, never as direct calls: a direct `setProviderCap` on an unlisted
  provider reverts (`_validateProvider`);
- add a test with a fake strategy.

### R4. MEDIUM, REQUIRED: phase 4 / monitor do not check which fToken `FluidProvider` wraps

`ops/src/checks/deployment.ts:139-150` compares provider addresses with the
manifest only. Add after the cap loop:
```ts
if (c.FluidProvider) {
  const fToken: string = await new Contract(c.FluidProvider, ['function fToken() view returns (address)'], provider).fToken();
  check(!!entry.strategy.fluidFToken && eq(fToken, entry.strategy.fluidFToken), 'FluidProvider wraps the registry fToken', fToken);
}
```
Add a unit test with a fake provider contract if the existing check tests use
fakes; otherwise cover it in the rehearsal phase 4 output.

### R5. LOW, REQUIRED: the interest-free branches of the rate formula are untested

On the test date both ratios of USDC were 0, so the fork test
(`testRateIsTheAccrualOfTheSupplyExchangePrice`) exercises only the "all supply
and borrow with interest" path. Required:
1. Change `_supplyYield` from `private` to `internal` (no behavior change) and add
   `test/unit/FluidProviderRate.t.sol` with a harness contract
   (`contract Harness is FluidProvider`) whose constructor can be satisfied:
   - either deploy the harness against small mocks of fToken, asset and
     Liquidity that implement `asset()`, `getData()` and code length;
   - or factor the math into a `library FluidRateLib` used by `FluidProvider`.
     The library is simpler to test; choose it if the change stays mechanical.
2. Vectors, each computed independently from Fluid's `LiquidityCalcs` source
   (document the arithmetic in comments):
   - ratios 0/0;
   - supply ratio even (interest-free supply smaller), e.g. `supplyRatio = 2000 << 1`;
   - supply ratio odd (interest-free larger), e.g. `(5000 << 1) | 1`;
   - borrow ratio even and odd likewise;
   - `supplyRatio == 1` or `borrowRatio == 1` gives 0; `borrowRate == 0` gives 0;
   - maxima `borrowRate = 0xffff`, `utilization = 0x3fff`, fee `1e4`: no overflow.
3. Keep the fork accrual test as the end-to-end reference.

### R6. LOW, REQUIRED: unused interface member

`contracts/interfaces/fluid/IFluid.sol:23` declares `minDeposit()`, which is not
used. Remove it, or use it in a fork test asserting `minDeposit()` stays below
the smallest planned rebalance amount. Choose removal unless the test adds value.

### R7. INFO, DO NOT CHANGE: withdrawals beyond Fluid's limit revert as a whole

`FluidProvider.withdraw` (line ~44) withdraws exactly `amount`. Above Fluid's
withdrawable amount it reverts; `Rebalancer._withdraw` then moves on to the next
provider, and Fluid is last in the list. Do NOT clamp to `maxWithdraw`: the
rebalance path expects exact amounts. Document the behavior in the provider's
NatSpec if it is not already clear.

## 4. Verification checklist

- [ ] Section 0 done (419 fixes in, rebased).
- [ ] R1 review request written; deployment gated on sign-off in the runbook.
- [ ] R2.1 confirmed; R2.2 implemented or explicitly deferred in verification.md.
- [ ] R3 guard with a test (hardhat script logic can be unit-tested by extracting
      the check into a function taking `providers` and `onChain`).
- [ ] R4, R5, R6 done; R7 NatSpec checked.
- [ ] `forge build` without warnings in `FluidProvider.sol` and the new test files.
- [ ] `forge test --no-match-path 'test/forking/*'` passes; fork tests 6/6 and
      4/4 still pass on an archive RPC.
- [ ] `cd ops && npm test` passes (apart from anything 419-R8 left deferred).
- [ ] `changes/ts-420-ethereum-fluid-provider/verification.md` updated.

## 5. Out of scope, do not do

- Changing `Rebalancer.sol`, the Fluid cap, or the provider order.
- Counting Fluid rewards in `getDepositRate`.
- Any deployment, governance transaction, push to `main` or force push.
