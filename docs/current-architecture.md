# Current architecture (`dev` @ `f053106`)

Phase 0 deliverable of the cross-chain Tick/Epoch initiative. Everything below is
read from the code on `dev` unless a line says otherwise; line numbers refer to
`dev` @ `f053106` (2026-09-21). Where the live chains are described, the source
is `deployments/ADDRESSES.md` and `audit/scope-2026-09-fee-cap-25.md`, which record
read-only on-chain observations of 2026-09-21.

> **Scope note (added 2026-09-28).** This document is the Phase 0 record of `dev`
> and is kept as written. Several of its "sandbox-only" and "not fixed on `dev`"
> statements have since been implemented independently on
> `feat/crosschain-tick-epoch`, in `contracts/Rebalancer.sol` and
> `contracts/interfaces/IRebalancer.sol` — the only two pre-existing contract
> files that branch modifies. Each affected line carries an inline
> `Since this branch:` marker. Summary:
>
> | Statement below | Status on `feat/crosschain-tick-epoch` |
> |---|---|
> | No reentrancy guard (§2, §12.4) | Implemented: `nonReentrant` on `deposit`, `mint`, `withdraw`, `redeem` and `rebalance` |
> | Provider views unbounded (§2/§5.3, §12.4) | Implemented: `getDepositBalance{gas: PROVIDER_VIEW_CALL_GAS}` with `PROVIDER_VIEW_CALL_GAS = 3_000_000` |
> | Provider views not wrapped, so a broken provider freezes `totalAssets()` (§7) | Implemented: `_safeGetDepositBalance` returns `(0, false)` on failure; `providersHealthy()` exposes the state; entry paths refuse deposits while any provider is unhealthy, exits still pay |
> | Removing a provider does not revoke its approval (§5, §12) | Implemented, best-effort: `try this.revokeStaleApproval(old)` and `StaleApprovalRevokeFailed` on failure. The entry provider also cannot be delisted (`EntryProviderNotInProviders`) |
> | Rebalance uses the requested amount, not the measured one (§4.3, §12.3) | Implemented: the deposit leg uses the measured balance delta `received`, and `_enforceProviderCap(to)` runs after it |
> | No exposure caps (§7, §12.7) | Implemented per provider: `setProviderCap`, in bps of `totalAssets()`, `0` = uncapped. `capBps` may only be lowered by ADMIN; raising or removing needs the Timelock |
> | Performance fee uses a rolling baseline, not a HWM (§3, §12.5) | **Still true.** Sandbox Finding 6 was deliberately not ported, because it changes fee semantics for the live vaults |
> | ProxyAdmin owned by an EOA, SEC-001 (§6) | **Still true for the live vaults.** The new cross-chain proxies are Safe-owned from deployment |

## 1. One-paragraph summary

Thesauros today is a **set of independent single-chain vaults**. On each chain
one `Rebalancer` proxy is simultaneously the share token and the vault. It holds
no idle asset; all assets sit in external lending markets reached through
**delegatecalled provider adapters** (Aave V3, Compound V3, MetaMorpho). NAV is
computed **synchronously on-chain** as the sum of provider balances. Deposits and
withdrawals execute instantly at that NAV. A privileged `EXECUTOR_ROLE` can move
assets only **between providers already on the vault's list**; the list itself
changes only through a `Timelock`. There is **no cross-chain code, no oracle, no
reported NAV, no queue, no epoch and no in-flight accounting on `dev`**. Chains do
not know about each other.

## 2. Contracts

| Contract | File | Lines | Role |
|---|---|---|---|
| `Rebalancer` | `contracts/Rebalancer.sol` | 948 | Vault + ERC-20 share token (ERC20Permit), ERC-4626-shaped API, fees, provider routing |
| `AccessManager` | `contracts/access/AccessManager.sol` | 99 | Minimal role registry: `ADMIN_ROLE` (0x00), `EXECUTOR_ROLE` |
| `PausableActions` | `contracts/utils/PausableActions.sol` | 84 | Per-action pause: `Deposit`, `Withdraw` |
| `Timelock` | `contracts/access/Timelock.sol` | 291 | Compound-style queue/execute, `Ownable2Step`, delay 30 min to 30 days, 14-day grace |
| `AaveV3Provider` | `contracts/providers/AaveV3Provider.sol` | 135 | Aave V3 supply/withdraw; balance = aToken `balanceOf` |
| `CompoundV3Provider` | `contracts/providers/CompoundV3Provider.sol` | 147 | Comet supply/withdraw; Comet address from `ProviderManager` |
| `MorphoProvider` | `contracts/providers/MorphoProvider.sol` | 237 | MetaMorpho vault deposit/withdraw; conservative balance (see 5.3) |
| `ProviderManager` | `contracts/utils/ProviderManager.sol` | 88 | `Ownable2Step` registry: identifier → asset → yield token / market |
| `VaultFactory` | `contracts/utils/VaultFactory.sol` | 88 | Deploys proxy and initializes it in one transaction (anti-front-running) |
| `ProxyImports` | `contracts/utils/ProxyImports.sol` | 5 | Makes the OZ proxy artifact available to hardhat-deploy |
| `Constants` | `contracts/libraries/Constants.sol` | 6 | `SCALE = 1e18`, `MAX_MANAGEMENT_FEE = 5%`, `MAX_PERFORMANCE_FEE = 25%` |

Verified assumptions:

* **ERC-4626**: shape only. `contracts/interfaces/IERC4626.sol` is a local copy.
  `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` return a hard-coded `0`
  (`Rebalancer.sol:174-192`), which is non-compliant on purpose ("avoid
  over-promising"). ERC-4626 integrators that respect `max*` cannot use the vault.
* **Proxies**: yes. OpenZeppelin 5.4 `TransparentUpgradeableProxy`; the proxy
  constructor creates its own `ProxyAdmin` (`VaultFactory.sol:57-61`,
  `deploy/deploy-usdc-vault.ts`).
* **Storage**: ERC-7201 namespaces. `thesauros.storage.Rebalancer`
  (`Rebalancer.sol:32-55`), `thesauros.storage.AccessManager`
  (`AccessManager.sol:17-24`) and `thesauros.storage.PausableActions`
  (`PausableActions.sol:14-22`). The linear layout is empty. New fields are safe
  only if appended to the end of a namespaced struct, or placed in a new namespace.
* **OpenZeppelin roles**: no. `AccessManager` is a stripped-down clone of
  `AccessControl`: no role admins, no enumeration, and `ADMIN_ROLE` grants and
  revokes everything (`AccessManager.sol:52-65`).
* **Reentrancy guard**: none on `dev`. It exists only on the unmerged
  `crosschain-sandbox` branch (Finding 3, commit `b84b14a`).
  *Since this branch:* implemented in `contracts/Rebalancer.sol` —
  `ReentrancyGuardUpgradeable` with `nonReentrant` on `deposit`, `mint`,
  `withdraw`, `redeem` and `rebalance`. The guard uses its own OZ namespace and
  works uninitialized, so the change is storage-compatible.

## 3. Share and accounting model

```
totalAssets() = Σ_i provider_i.getDepositBalance(vault)              Rebalancer.sol:152, 855-866
shares(deposit a) = a · supply' / totalAssets     (floor)             Rebalancer.sol:233-248, 354-364
assets(redeem s)  = s · totalAssets / supply'     (floor)             Rebalancer.sol:294-310, 367-377
supply' = totalSupply + pending fee shares                            Rebalancer.sol:313-350
```

* **Idle asset is not NAV.** Tokens held by the vault address itself are never
  counted. Donations therefore cannot reprice shares, but tokens left behind by
  a short provider withdrawal also become invisible.
* **Inflation protection** comes from a seed deposit of `minAssets` minted to the
  vault itself during `initialize` (`Rebalancer.sol:124-126`); these are dead
  shares. There is no virtual-share offset.
* **Rounding** favours the vault: shares on deposit are floored, shares on
  withdraw are ceiled, and assets on redeem are floored.
* **Fees** are paid by minting shares to the treasury (`_applyFees`,
  `Rebalancer.sol:564-592`). The management fee is `NAV · fee · dt / 365d`. The
  performance fee is charged on `NAV − _lastTotalAssets`. **This is a rolling
  baseline, not a high-water mark**: a loss followed by a recovery is charged
  again (pinned by
  `test/unit/PerformanceFeeCap.t.sol:641-679`,
  `testPerformanceFeeAtCapUsesRollingBaselineNotHighWaterMark`). A real HWM exists
  only on `crosschain-sandbox`. Every deposit, mint, withdraw and redeem settles
  fees first. Both fee rates are set by `ADMIN_ROLE` with no timelock. Both are 0
  on every live chain.
  *Since this branch:* still true for `Rebalancer` — sandbox Finding 6 was
  deliberately not ported, because it changes fee semantics for the live vaults.
  A real high-water mark does exist on this branch, but in `TickAccountant`
  (`_highWaterMark`, updated only on an accepted Tick, and not raised by
  `ratifyTick`), which is where the cross-chain vault's own fees are charged.
  The strategy `Rebalancer` instances are deployed with both fees at 0.

## 4. Flows

### 4.1 Deposit (`deposit`/`mint`, `Rebalancer.sol:233-268, 386-399`)

1. `_applyFees()` settles accrued fees and reads live `totalAssets`.
2. Shares are computed at that live NAV.
3. `_validateDeposit` requires `Actions.Deposit` not paused, `assets ≥ minAssets`
   and a non-zero receiver.
4. `safeTransferFrom(caller → vault)`, then a delegatecall of
   `entryProvider.deposit(assets, vault)`.
5. Shares are minted immediately. There is no lock, no pending state, and nothing
   restricts transfers.

### 4.2 Withdraw (`withdraw`/`redeem`, `Rebalancer.sol:273-310, 409-455`)

1. Fees are settled, then assets or shares are computed at the live NAV.
2. The owner's shares are burned **first**.
3. The vault walks `_providers` in list order. For each provider it delegatecalls
   `withdraw(amount, vault)` with a **low-level delegatecall that swallows
   failures** (`:436-446`) and measures what actually arrived by balance delta.
4. If the loop cannot collect the full amount, it reverts with
   `InsufficientLiquidity`. The withdrawal is all-or-nothing; there is no queue
   and no partial fill.

### 4.3 Rebalance (`rebalance`, `Rebalancer.sol:511-552`)

* Only `EXECUTOR_ROLE` can call it. It takes arrays `(amount, from, to)`, and both
  providers must be in `_providers` (`_validateProvider`, `:872-883`).
* It delegatecalls `from.withdraw(assets)`, then `to.deposit(assets)`, **using the
  requested amount, not the measured one**. A provider that returns less makes
  the deposit either consume idle vault balance or revert. (The
  `crosschain-sandbox` design notes record the same observation.)
  *Since this branch:* fixed. `rebalance` measures the balance delta released by
  the source and deposits exactly that (`received`), reverts on `received == 0`,
  and then runs `_enforceProviderCap(to)`. `amounts[i] == type(uint256).max`
  means "move everything the source holds". It is also `nonReentrant`.
* It does no NAV check before or after, and has no per-provider exposure cap, no
  amount limit and no rate limit.
  *Since this branch:* a per-provider exposure cap exists
  (`_enforceProviderCap`, `ProviderCapExceeded`). There is still no NAV check, no
  per-call amount limit and no rate limit on `rebalance`.

## 5. Protocol integrations

All three adapters are **stateless** and **delegatecalled**: they execute with
the vault's storage, balance and approvals. Adding a provider is therefore
equivalent to adding code that runs with full vault authority. The only thing
guarding that is the `Timelock` delay on `setProviders` (`Rebalancer.sol:664-666`).
`setProviders` also grants the new provider's `getSource` address an unlimited
approval (`:736-739`). On `dev`, removing a provider does **not** revoke its
approval (Finding 4, fixed only on the sandbox branch).
*Since this branch:* implemented, best-effort. `_setProviders` keeps the entry
provider listed (`EntryProviderNotInProviders`) and, for every removed provider,
calls `try this.revokeStaleApproval(oldProviders[i])` — a self-call so a provider
that reverts on `getSource` or `approve` cannot block its own removal — emitting
`StaleApprovalRevokeFailed` if it fails. A removal therefore succeeds even when
the allowance could not be cleared, and the stale unlimited approval survives.

### 5.1 Aave V3 (`AaveV3Provider.sol`)

* **Value:** `aToken.balanceOf(vault)` for `vault.asset()`. The pool is resolved
  through the `PoolAddressesProvider` passed to the constructor (THES2-2 fix).
* **Accrued interest:** already included, because aToken balances rebase.
* **Liquidity:** withdrawals fail when utilization leaves no free liquidity.
  Valuation does not reflect this.

### 5.2 Compound V3 (`CompoundV3Provider.sol`)

* **Value:** `comet.balanceOf(vault)`, which includes accrued supply interest.
  The Comet address comes from `ProviderManager.getYieldToken("Compound_V3_Provider", asset)`.
  `ProviderManager` is owned by an EOA with **no timelock**, and it controls which
  Comet the vault approves and deposits into (finding
  `2026-08-06-meridian-vault-provider-manager-untimelocked`).
* **Rewards:** COMP rewards are not claimed or counted anywhere.

### 5.3 Morpho (`MorphoProvider.sol`)

The value is the vault's MetaMorpho shares priced conservatively
(`getDepositBalance`, `:148-181`):

* **Assets per share:** `min(realAssets, bookAssets)`. `realAssets` is the sum of
  `expectedSupplyAssets` over the withdraw queue; `bookAssets` is
  `MetaMorpho.totalAssets()`. This excludes unrealized bad debt (THES2-3 fix).
* **Pending fees:** fee shares that MetaMorpho has not yet minted are added to the
  denominator.
* **Gas:** the loop over the withdraw queue is **O(queue length)**. The sandbox
  branch measured up to about 1.1M gas for one call.
  *Since this branch:* the call is made under a stipend,
  `getDepositBalance{gas: PROVIDER_VIEW_CALL_GAS}` with
  `PROVIDER_VIEW_CALL_GAS = 3_000_000`, and never reverts: a provider that runs
  out of gas reads as `(0, false)`. The loop is still O(queue length), but it can
  no longer consume unbounded gas or freeze `totalAssets()`.

Deployed MetaMorpho instances per `deployments/ADDRESSES.md`: **three on Base,
three on Arbitrum, three on Ethereum, and none on Plasma or Monad** — those two
deploy an `AaveV3Provider` only, with no Morpho provider and no
`CompoundV3Provider`. The three instances per chain are not the same three
families:

| Chain | Morpho provider deployments |
|---|---|
| Base | `GauntletCoreMorphoProvider`, `SteakhouseHighYieldMorphoProvider`, `SteakhousePrimeMorphoProvider` |
| Arbitrum | `GauntletCoreMorphoProvider`, `SteakhouseHighYieldMorphoProvider`, `SteakhousePrimeMorphoProvider` |
| Ethereum | `GauntletPrimeMorphoProvider`, `SmokehouseMorphoProvider`, `SteakhouseMorphoProvider` |
| Plasma, Monad | none |

So `Smokehouse` exists only on Ethereum, `SteakhouseHighYield`/`SteakhousePrime`
only on Base and Arbitrum, and `Gauntlet` appears as `GauntletCore` on the L2s and
`GauntletPrime` on Ethereum. One `MorphoProvider` *contract* serves all of them;
each deployment is a separate instance pointing at one MetaMorpho vault.

**LP strategies:** none exist in this repository.

## 6. Access control

| Actor | Powers | Where |
|---|---|---|
| `ADMIN_ROLE` | Grant and revoke any role; pause and unpause; `setEntryProvider`; `setTreasury`; fees; `minAssets` | `Rebalancer.sol:651-724`, `AccessManager.sol:52-65` |
| `EXECUTOR_ROLE` | `rebalance` between listed providers | `Rebalancer.sol:511-515` |
| `Timelock` (vault's `_timelock`) | `setProviders`, `setTimelock` | `Rebalancer.sol:664-685` |
| `Timelock.owner()` | queue, execute and cancel after the delay | `Timelock.sol:153-266` |
| `ProviderManager.owner()` | Point the Compound identifier at any address | `ProviderManager.sol:31-59` |
| `ProxyAdmin.owner()` | Replace the vault implementation instantly | OZ 5.4 |

What the `EXECUTOR_ROLE` cannot do is important for the new design, because it
already implements most of what the brief calls "constrained rebalancer
permissions" for a single chain:

* It cannot move tokens to any address other than a listed provider's source,
  because the providers hard-code the recipient as `address(vault)`.
* It cannot approve a spender, cannot call arbitrary targets and cannot mint or
  burn shares.

Its worst case is **allocation risk**: concentrating everything in the weakest
listed market. It is not theft. Arbitrary execution only becomes possible through
the Timelock (new provider code) or the ProxyAdmin (new implementation).

**Live trust roots (2026-09-21).** On Base, Arbitrum, Plasma and Monad,
`ProxyAdmin.owner()` is the deployer EOA `0xafA9…8F9D`: that is SEC-001, Critical,
open. On Ethereum, the ProxyAdmin, the vault `ADMIN_ROLE`, the treasury, the
Timelock owner and the ProviderManager owner are all that same EOA ("interim").
One key can therefore replace the code of every vault instantly. Any cross-chain
design that adds a NAV updater role **inherits this ceiling**: no NAV corridor
protects against a key that can swap the implementation.

## 7. Oracles, risk limits and emergency mechanisms

* **Oracles:** none. Every vault holds one asset, so NAV is in asset units with
  no price feed. Plasma's vault holds **USDT0**, not USDC. A single global NAV
  across Plasma and the USDC chains would need an FX assumption that the code
  does not make today.
* **Risk limits:** `minAssets` per deposit, the two fee caps and the Timelock
  delay bounds. There are **no exposure caps, TVL caps, rate limits or deposit
  caps**.
  *Since this branch:* per-provider exposure caps exist (`setProviderCap`, in bps
  of `totalAssets()`, enforced after every deposit into the entry provider and
  after every rebalance). `capBps == 0` means uncapped and is the default; ADMIN
  may only lower a cap, raising or removing one needs the Timelock. Still no TVL
  cap, no rate limit and no deposit cap on `Rebalancer` itself — the cross-chain
  vault's caps live in `EpochVault.Limits` instead.
* **Emergency:** `pause(Deposit)` and `pause(Withdraw)` by `ADMIN_ROLE` only. There
  is no guardian role that can pause without also being able to unpause, and no
  pause on `rebalance`. The withdraw loop tolerates a reverting provider, so a
  single broken market does not freeze exits. It does freeze `totalAssets()`,
  though, because provider views are not wrapped (Finding 2, sandbox-only fix).
  *Since this branch:* provider views are wrapped (`_safeGetDepositBalance`,
  `PROVIDER_VIEW_CALL_GAS = 3_000_000`), so a broken market no longer freezes
  `totalAssets()`; it reads as 0 and sets `providersHealthy()` false, which
  refuses deposits while still paying exits. `Rebalancer` still has no guardian
  role and still no pause on `rebalance`. A guardian role does exist on this
  branch, but on the new contracts: `GUARDIAN_ROLE` on `EpochVault`,
  `TickAccountant` and `ChainAgent`, where it can pause but not unpause.

## 8. Upgradeability

* **Implementation upgrades:** `ProxyAdmin.upgradeAndCall` performs them. `dev`
  has no `reinitializer`.
* **Upgrade tooling:** `scripts/upgrade-vault-implementation.ts` gates an upgrade
  on the storage layout, the ERC-7201 slots, the ABI superset and a source diff.
  Its source gate currently allows **only** `contracts/libraries/Constants.sol` to
  change. Any upgrade of the kind this initiative needs has to widen that gate
  deliberately.
* **Sandbox branch:** its `initializeV2()` (reentrancy guard plus HWM bootstrap)
  shows the intended migration pattern, which is to append fields at the end of
  the namespaced struct.

## 9. Tests

| Suite | Kind | Notes |
|---|---|---|
| `test/unit/PerformanceFeeCap.t.sol` | Unit and fuzz, fork-free, 17 tests | The only fork-free suite on `dev`. Its doubles (`FeeCapAsset`/`FeeCapSource`/`FeeCapProvider`) model the delegatecall discipline correctly and are the right base for new unit tests |
| `test/forking/*Provider.t.sol` | Base fork | One suite per provider |
| `test/forking/ForkingBase.t.sol`, `ForkingEthereum.t.sol` | Fork | Full stack, including the atomic `VaultFactory` path |
| `test/forking/NewVaultWithdraw.t.sol` | Manual trace | Needs env vars and fails without them; documented in `audit/scope-2026-09-fee-cap-25.md` §7.3 |

* **Framework:** Foundry for everything (`foundry.toml`). Hardhat has zero Mocha
  tests; it is used for deployment only.
* **Missing on `dev`:** invariant and handler tests. They exist on
  `crosschain-sandbox` (`test/invariant/*`, Finding 8).
  *Since this branch:* a handler-based invariant suite exists in-tree —
  `test/tick/CrossChainInvariants.t.sol`, 6 invariants, 256 runs × 500 calls,
  driving only public entry points with real token movement.
* **CI** (`.github/workflows/security.yml`): Slither (`fail-on: high`) and
  `npm audit` only. **Tests do not run in CI.** Slither trips on a known
  `arbitrary-send-erc20` false positive in `VaultFactory.sol:65`.
  *Since this branch:* still no tests in CI, and the High-impact set grows by
  five results on new code (`EpochVaultLogic._pullExact`, and `reentrancy-balance`
  on `ChainAgent.bridgeOut` / `deallocate` / `deallocateShares` /
  `receiveBridge`). All are false positives and all are disclosed with their
  reasoning in `docs/implementation-report.md` §18.
* **Local baseline (2026-09-27):** `forge build` succeeds and
  `forge test --match-path test/unit/PerformanceFeeCap.t.sol` gives 17/17 passed.

## 10. Deployment

* `deploy/deploy-usdc-vault.ts` (hardhat-deploy) deploys the providers,
  `ProviderManager`, `Timelock` and the implementation. On Ethereum it uses
  `VaultFactory.deployAndInitialize`; elsewhere it uses a three-step pipeline.
* `scripts/*.ts` are per-chain operational checks and the upgrade tool.
* Live vaults: Base, Arbitrum, Plasma, Monad and Ethereum. The only material
  balance is Arbitrum (≈50.8k USDC on 2026-09-21); the others hold 1 to 6 units.

## 11. Code outside `dev` that bears on this initiative

| Location | What | Status | Relevance |
|---|---|---|---|
| `crosschain-sandbox` (this repo) | Findings 1–8 hardening of `Rebalancer` (reentrancy, bounded provider views, HWM, approval revocation, entry-provider check), invariant suite, `VaultDeployer` | Unmerged. Reviewed internally, not externally audited | Should be the base of any new `Rebalancer` generation |
| `crosschain-sandbox` (this repo) | `MeshNode`, `MeshProvider`, `MeshCustodian`, `CCTPMeshBridgeAdapter`, `CCTPRelayReceiver` | Unmerged. A "mainnet stand" deploy script exists | Route model and measured-delta accounting are reusable; see the design doc §9 |
| `thesauros.io/contracts`, branch `crosschain` | Legacy `CrossChainVault` + `ReportSettler` + `WithdrawalQueue` + Stargate/LZ | **Live on Base mainnet, accounting diverged (SEC-018)** | Negative example; root cause below |

*Since this branch:* the sandbox was **not** merged and was not used as the base.
`feat/crosschain-tick-epoch` re-implemented the relevant `Rebalancer` hardening
directly on top of `dev` (reentrancy guard, bounded and wrapped provider views,
approval revocation, entry-provider check, per-provider caps, measured rebalance),
storage-compatibly and without the fee HWM. The sandbox remains the source of the
route model and measured-delta accounting ideas that `ChainAgent` follows (§9 of
the design doc), and its invariant suite is the shape `test/tick/CrossChainInvariants.t.sol`
takes. See §13.

**SEC-018 root cause**, established during this Phase 0 from the legacy code plus
read-only Base RPC and explorer data:

* The legacy vault debited its `homeIdle` ledger by 3.7 USDC when a keeper set an
  operation's status to `Sent`. **The operation was never dispatched**:
  `getOperationDispatch` for it is all zeros, and only two USDC transfers ever
  touched the vault.
* A later attested report set the strategy's value to 0.

The general failure is **accounting moved by keeper-set status flags instead of by
measured token movement**. The legacy fuzz tests call `setOperationStatus` without
a dispatch, so they certify the defect as correct. The legacy vault still accepts
deposits at the broken price: `previewDeposit(1 USDC)` returns about 24 shares.
See the threat model, §3.

## 12. Defects and gaps on `dev` relevant to the new design

1. NAV is synchronous and single-chain. Nothing can represent a remote or
   in-flight position.
2. Deposits and withdrawals are instant at live NAV. Once any part of NAV is
   lagged, that is exactly the stale-NAV arbitrage surface the brief is about.
3. The rebalance leg uses requested amounts, not measured ones (§4.3).
   *Since this branch: fixed* — the deposit leg uses the measured delta.
4. There is no reentrancy guard, and provider views are unbounded (both fixed
   only on the sandbox branch).
   *Since this branch: both fixed*, independently of the sandbox — `nonReentrant`
   on every state-changing entry point, and `PROVIDER_VIEW_CALL_GAS = 3_000_000`
   with a `(0, false)` fallback in `_safeGetDepositBalance`.
5. Performance fees use a rolling baseline, not a HWM. *Still true for
   `Rebalancer`*; the new `TickAccountant` has a real HWM.
6. Fee changes and ProviderManager changes are not timelocked. The ProxyAdmin is
   owned by an EOA (SEC-001). *Still true.* On this branch `TickAccountant.setFees`
   **is** `onlyTimelock`, but `Rebalancer.setManagementFee` /
   `setPerformanceFee` remain `ADMIN_ROLE` with no delay, and the cross-chain
   strategies are `Rebalancer` instances.
7. There is no guardian role (pausing and unpausing need the same key), no
   rebalance pause, and no exposure or TVL caps.
   *Since this branch: partly fixed* — per-provider exposure caps exist, and a
   guardian role exists on `EpochVault`, `TickAccountant` and `ChainAgent` (pause
   without unpause). `Rebalancer` itself still has no guardian and no rebalance
   pause, and there is still no TVL cap.
8. CI runs no tests. *Still true.* CI is Slither (`fail-on: high`) and `npm audit`
   only; see `docs/implementation-report.md` §18 for the High-impact results this
   branch adds.

## 13. What `feat/crosschain-tick-epoch` adds, and what it reuses

This section is the only one in this document that is not scoped to `dev`.

### 13.1 Reused byte-identical

`git diff --name-status dev..HEAD -- contracts/` shows exactly two modified files
(`Rebalancer.sol`, `interfaces/IRebalancer.sol`); everything else under
`contracts/` on that branch is new. So the following are **unchanged source**,
carried over as-is:

| Component | Source vs `dev` | Deployed instance on the cross-chain chains |
|---|---|---|
| `AccessManager` | byte-identical | inherited by every new contract |
| `Timelock` | byte-identical | a fresh instance per chain, Safe-owned, 24 h delay |
| `PausableActions` | byte-identical | used by the strategy `Rebalancer`s |
| `AaveV3Provider`, `CompoundV3Provider`, `MorphoProvider` | byte-identical | see 13.3 |
| `ProviderManager` | byte-identical | a fresh instance per chain, for Comet only |
| `VaultFactory` | byte-identical | a fresh instance per chain, for atomic proxy deploy |
| `ProxyImports` | byte-identical | artifact only |
| `Constants` | byte-identical | `SCALE`, `MAX_MANAGEMENT_FEE` 5%, `MAX_PERFORMANCE_FEE` 25% |
| `Rebalancer` | **modified** (hardened, storage-compatible) | new per-chain strategy instances; the live public vaults are not upgraded |

### 13.2 Added

`contracts/tick/{NavSnapshot,TickAccountant,EpochVault,EpochVaultLogic,EpochVaultStorage}.sol`
and their interfaces; `contracts/crosschain/ChainAgent.sol`,
`interfaces/IBridgeAdapter.sol`, `bridges/CctpV2Adapter.sol`;
`deploy/crosschain/*`; `ops/*`; `test/tick/*`, `test/unit/RebalancerHardening.t.sol`,
`test/forking/CctpV2Adapter.t.sol`.

### 13.3 The reuse that is not visible in the source tree

The new per-chain strategy `Rebalancer`s are wired to the **already-deployed**
Base and Arbitrum Aave and Morpho provider contracts. `deploy/crosschain/registry.ts`
lists them under `strategy.reusedProviders`, and `01-deploy.ts` passes those
addresses straight into the strategy's provider list rather than deploying new
adapters:

| Chain | Reused, already deployed | Deployed fresh by phase 1 |
|---|---|---|
| Base (hub) | `AaveV3Provider` `0xDDAA…317c`, `GauntletCoreMorphoProvider` `0x51B8…1b8b`, `SteakhouseHighYieldMorphoProvider` `0x9c35…C61c`, `SteakhousePrimeMorphoProvider` `0xDDf2…95b1` | `ProviderManager` + `CompoundV3Provider` for Comet `0xb125…Eb2F`, `Timelock`, `VaultFactory`, the strategy `Rebalancer`, `ChainAgent`, `CctpV2Adapter`, and — hub only — `TickAccountant` and `EpochVault` (+ `EpochVaultLogic`) |
| Arbitrum (spoke) | `AaveV3Provider` `0xA345…13A5`, `GauntletCoreMorphoProvider` `0xeB98…40d7`, `SteakhouseHighYieldMorphoProvider` `0x6240…8B99`, `SteakhousePrimeMorphoProvider` `0x0D9F…3484` | `ProviderManager` + `CompoundV3Provider` for Comet `0x9c4e…F58bf`, `Timelock`, `VaultFactory`, the strategy `Rebalancer`, `ChainAgent`, `CctpV2Adapter` |

Addresses match `deployments/ADDRESSES.md` for Base and Arbitrum. Details worth
stating:

* `01-deploy.ts` splices the fresh `CompoundV3Provider` in at index 1, so the
  first reused provider (Aave) stays the entry provider — every deposit lands
  there, which is why it must remain uncapped (§7 marker).
* These provider adapters are shared with the live public vaults, so a change to
  one would affect both. They are stateless immutable configurations, which is
  what makes reusing them safe.
* A fresh `ProviderManager` is deployed rather than reusing the live one, because
  the live one's owner is an EOA with no timelock (§5.2). The new one is created
  with the deployer as owner for setup and its ownership is offered to the Safe
  in phase 3 (`03-handover.ts`, two-step `Ownable2Step`). It only ever holds the
  Comet mapping for the new strategies.
