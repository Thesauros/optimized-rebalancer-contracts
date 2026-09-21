# Audit scope: MAX_PERFORMANCE_FEE cap raise 20% to 25%

Date of every on-chain observation below: 2026-09-21, via read-only `eth_call` /
`eth_getStorageAt` / `eth_getCode` against public RPC endpoints. No transaction was
sent by anyone in the preparation of this document.

Repository: `optimized-rebalancer-contracts`
Branch under review: `feat/fee-cap-25`, cut from `dev` at `ce1be23aff406be45d8f2215258d494ff70099e3`

Product context: the published terms state a 25% performance fee on generated yield
with nothing charged on principal. The deployed contracts cap that fee at 20% and
every live vault runs with both fees at zero. This change raises the cap so the
contracts can be configured to match the published terms. Setting a non-zero fee is a
separate governance action and is outside this diff.

---

## 1. The diff

One line of Solidity, in one file.

```
contracts/libraries/Constants.sol
-uint256 constant MAX_PERFORMANCE_FEE = 0.2 * 1e18; // 20%
+uint256 constant MAX_PERFORMANCE_FEE = 0.25 * 1e18; // 25%
```

`MAX_MANAGEMENT_FEE` stays at `0.05 * 1e18` and `SCALE` stays at `1e18`.

Reachability, established by grep over `contracts/` at this commit:

| fact | evidence |
|---|---|
| `Constants.sol` has exactly one importer | `contracts/Rebalancer.sol:16` |
| `MAX_PERFORMANCE_FEE` is read at exactly one site | `contracts/Rebalancer.sol:803`, inside `_setPerformanceFee(uint96)` |
| `_setPerformanceFee` has exactly two callers | `initialize(...)` (`Rebalancer.sol:119`) and `setPerformanceFee(uint96)` (`Rebalancer.sol:715`) |
| `setPerformanceFee` is gated by | `onlyRole(ADMIN_ROLE)`, and calls `_applyFees()` before storing |
| revert on breach | `IRebalancer.InvalidInput()` |

History of the value: `git log --all -S 'MAX_PERFORMANCE_FEE = 0.2 * 1e18' -- contracts/libraries/Constants.sol`
returns exactly one commit, `2d411b401722218c39e81e78b3d735d4d30843bf` (2026-01-16,
"update mfee logic and add pfee"), which is an ancestor of `dev`. The constant held
`0.2 * 1e18` on every branch from that commit until this one.

### Compile-level effect

| property | live build (20% cap) | new build (25% cap) |
|---|---|---|
| `keccak256` of `deployedBytecode` | `0xc88383885f0e303fbe2849d454ac98a0e7c89788b6f06709275ac06b3cfc5e70` | `0x9843250c35e327ec40e78f3ba3dd84363d08c5d8dd7cc334c09863356c141d27` |
| `sha256` of `deployedBytecode` | `0x6321859d3de5102ce578fff9b72a39f3c7a6e4d91c3a8b6bcedcfe0269755b32` | `0xc4240731bb52585953cc4b6a7d616bb36eee13ca379ce4a6c60eed18221074cf` |
| runtime code length | 16,929 bytes | 16,929 bytes |
| solc | `0.8.33+commit.64118f21` | `0.8.33+commit.64118f21` |
| optimizer | `{enabled: true, runs: 200}` | `{enabled: true, runs: 200}` |
| evmVersion | `paris` | `paris` |
| ABI function selectors | 57 | 57 (none removed, none added) |

evmVersion matters operationally: `forge build` on this machine targets `prague` and
produces different bytecode (`0xd6bb7e4f...`) for the same source. The new
implementation must be built and deployed through Hardhat, which targets `paris` here,
so the artifact stays comparable to the live generation and to the explorer
verification input. `scripts/upgrade-vault-implementation.ts` compiles through Hardhat
and asserts the deployed runtime code hash against the Hardhat artifact.

### Storage-compatibility evidence

| property | live build | new build |
|---|---|---|
| `storageLayout.storage` entries | `[]` | `[]` |
| `storageLayout` JSON | identical | identical |
| `RebalancerStorageLocation` | `0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00` | unchanged |
| `AccessManagerStorageLocation` | `0x269ca335d49f0b8bbf3a5a2cc9876243b5841edd3dfc837ebccdab385b0bb300` | unchanged |
| `PausableActionsStorageLocation` | `0x3269bba93b0c415a49697506f3e813e8145a2749219158acdaf45928901f6400` | unchanged |
| OZ `ERC20StorageLocation` / `EIP712StorageLocation` / `NoncesStorageLocation` | `0x52c63247...ace00` / `0xa16a46d9...7d100` / `0x5ab42ced...4bb00` | unchanged |

Every vault field lives behind an ERC-7201 namespace slot computed from a string
literal. The symbol that changed is a file-level `constant`, inlined into the
comparison at `Rebalancer.sol:803` at compile time; it occupies no storage slot and
appears in no layout. `_performanceFee` remains `uint96`, and `0.25e18 = 2.5e17` is
representable in `uint96` (max `7.92e28`).

---

## 2. The live generation, and how it is proved

### 2.1 Provenance chain

| step | result |
|---|---|
| `git rev-parse dev`, `origin/dev`, `https-origin/dev`, `v0.9.3^{commit}` | all `ce1be23aff406be45d8f2215258d494ff70099e3` (2026-09-13 16:19:14 +0300, "Ethereum-only atomic deploy path") |
| `git log main..dev` | empty; `main` = `047dc929d64eeef89e35adc79c8eeeaa2f2f6110` ("Merge branch 'dev'") contains all of `dev` |
| `git merge-base dev crosschain-sandbox` | `ce1be23...`, so `crosschain-sandbox` (`294929b2e8140544fec61c4d50dea078e91043ad`) is strictly ahead of `dev` |
| `keccak256(eth_getCode(impl))` per chain | `0xc88383885f0e303fbe2849d454ac98a0e7c89788b6f06709275ac06b3cfc5e70` on Base, Arbitrum, Plasma and Monad |
| `keccak256` of `deployments/<chain>/USDCRebalancerImplementation.json → deployedBytecode` | same value on all four chains |
| `sha256` of that recorded bytecode vs `npx hardhat compile` from a clean `dev@ce1be23` checkout | byte-identical, `0x6321859d3de5102ce578fff9b72a39f3c7a6e4d91c3a8b6bcedcfe0269755b32` |
| `metadata.sources['contracts/libraries/Constants.sol']` embedded in all four records | `uint256 constant MAX_PERFORMANCE_FEE = 0.2 * 1e18; // 20%`, solc `0.8.33+commit.64118f21`, optimizer `{enabled:true,runs:200}`, evmVersion `paris`, 34 sources |

Conclusion: all four live implementations are the same bytecode, and that bytecode is
what `dev@v0.9.3` compiles to with the Hardhat settings in this repository.

Deployment-record commits on `dev`:

| chain | commit | date | subject |
|---|---|---|---|
| Base | `11f829bcf2229323a1202cb82ed71271f3d040e0` | 2026-08-05 | base:deployed |
| Arbitrum | `faa095658f7683e75701b0aceb09e07acb6a5398` | 2026-08-06 | arbitrum:deploy |
| Plasma | `b42fba00b4f01c41d821ee34519574c7d155bc6e` | 2026-08-06 | plasma:deployed |
| Monad | `fc6e25460acffe1746e83e7939e51b10ab76c306` | 2026-08-06 | monad:deployed (tag `v0.9.1`) |

### 2.2 Remediation commits that ARE in `dev@v0.9.3`

Hexens July-2026 findings THES2-1, THES2-2, THES2-3. Each hash below satisfies
`git merge-base --is-ancestor <hash> dev`:

| commit | date | subject |
|---|---|---|
| `faacb59333ae070a69f951cb1be995ccf41001ac` | 2026-07-21 | Fix Hexens audit findings THES2-1 and THES2-3 |
| `814134aa58e1d09d22291a1180b901ee29d4d552` | 2026-07-21 | THES2-2: Migrate AaveV3Provider to constructor injection |
| `564de65abab4b6259a55e0546f0c61fc53a75f73` | 2026-07-22 | Merge pull request #7 from Thesauros/audit-fixes |
| `ed510592068f7d3839314cd011905a88385ecc8c` | 2026-07-22 | audit |
| `73260ec3931c2a00d1eebdd4d3fd53a59869731c` | 2026-07-24 | fix:THES2-3 (tag `v0.9.0`) |

Tags merged into `dev`: `v0.9.0`, `v0.9.1`, `v0.9.2`, `v0.9.3`.

### 2.3 Remediation commits that are NOT in `dev@v0.9.3`

A second, internal remediation series ("Finding 1" through "Finding 8") exists in this
repository but is reachable only from `crosschain-sandbox`. For every hash below,
`git merge-base --is-ancestor <hash> dev` is false and
`git branch -a --contains <hash>` lists only `crosschain-sandbox` and
`origin/crosschain-sandbox`:

| commit | date | subject |
|---|---|---|
| `c52568e12068346d737e2a67e482de618db6139b` | 2026-08-13 | feat(security): add VaultDeployer factory to close proxy front-running window (Finding 1) |
| `b84b14a08c8f49a6d881a12c0a5e3547b84b21dd` | 2026-08-13 | fix(security): harden Rebalancer.sol core vault logic (Findings 2,3,4,5,6,7) |
| `c703947b8e2c8e31da4d1bab214a69bbd4233b41` | 2026-08-13 | fix(security): reject execute() calls to the zero address in Timelock (Finding 7) |
| `d4035d70eaaf7d2de7852c1ab85298c6182f2bcc` | 2026-08-13 | test: add mock provider/yield-source/ERC20 fixtures for fast, fork-free testing |
| `3ce095512c5d04bc89d9e087f745995a6219425d` | 2026-08-13 | test: add Foundry fuzz/invariant suite for Rebalancer (Finding 8) |

Size of the gap, `git diff --numstat dev crosschain-sandbox -- contracts/`:
`contracts/Rebalancer.sol` +302 / −34, `contracts/interfaces/IRebalancer.sol` +13,
`contracts/access/Timelock.sol` +5, plus `contracts/VaultDeployer.sol` (181 lines, new)
and `contracts/crosschain/**` (new). `contracts/libraries/Constants.sol` is identical on
both branches.

What the unreleased `Rebalancer.sol` adds, from `git diff dev crosschain-sandbox`:
`initializeV2()` guarded by `reinitializer(2)`, a `$._highWaterMark` field with
`getHighWaterMark()`, `getProviderBalances()`, `_revokeStaleApproval(IProvider)`,
`_isProviderInList(...)`, `_safeGetDepositBalance(...)`, errors
`Timelock__AddressZero` and `EntryProviderNotInProviders`, and event
`StaleApprovalRevokeFailed`.

Consequence for this review, stated plainly: the implementation to be audited and
deployed here is `dev@v0.9.3` plus the one-line cap change. It carries none of the
Finding 1 to 8 hardening, and it has no high-water mark. Bringing that series into the
live generation is a diff two orders of magnitude larger than this one and needs its
own decision and its own review.

---

## 3. Live per-chain state

All four proxies hold 1,166 bytes of code (OpenZeppelin 5.4.0
`TransparentUpgradeableProxy`). All four ProxyAdmins return
`UPGRADE_INTERFACE_VERSION() == "5.0.0"`, meaning `upgradeAndCall(address,address,bytes)`
is the only upgrade entry point. `hasRole(ADMIN_ROLE, 0x3CDD9470...)` is true and
`hasRole(ADMIN_ROLE, 0xafA9ed53...)` is false on all four chains.

| | Base | Arbitrum | Plasma | Monad |
|---|---|---|---|---|
| chainId | 8453 | 42161 | 9745 | 143 |
| vault proxy | `0x3C7739173cca612B6394EE57131458185A5beC44` | `0x4E5c0A4C11d713002D74bA43a458efc31bc76378` | `0x2Ed9B7fB6Bbe0920145B2a79c18C3f7cFCAE3C99` | `0x40F1fBf6a92155a6D321c09936234BFEb9Ec4760` |
| implementation | `0xd4aC8Bcec0790ADDa563dB1B35c072B485fE2708` | `0xEd3296117dAAa46FE4Cf94036bb42EE86100F8c7` | `0x4382190FDbf4befA016Ea412f34eb54593312aD5` | `0x44eC9D49196749Cf647339350d381302af4a3d60` |
| **ProxyAdmin** | `0xb9a8f0f2E578cc1001553A8Ae0A168cAe48A894e` | `0xdAAd7B2be3cbC4fFFE954786e2cbA26e5de8cde5` | `0xb6Ccd1846BA0D2c7509Af8d603EE490B4D88E91e` | `0xCf9A835467bDD83DD3169e9473Aa8e1ed1904070` |
| **ProxyAdmin.owner()** | `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` (EOA) | `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` (EOA) | `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` (EOA) | `0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` (EOA) |
| `getPerformanceFee()` | 0 | 0 | 0 | 0 |
| `getManagementFee()` | 0 | 0 | 0 | 0 |
| `getTreasury()` | `0xafA9ed53...` (EOA) | Safe | Safe (no code on chain) | Safe (no code on chain) |
| `getTimelock()` | `0xb2b1A0c173549A498859822f20Da68be1bEA593D` | `0x694C38fb29fd14dECbBe11A15009aC7e728A686D` | `0xE1Cfb1BDb3901dcEe9F21146c1F299c775d9B65C` | `0x30dC35B78a401Fd0227C229ADF6d0F5097358EF9` |
| `Timelock.owner()` | EOA `0xafA9ed53...` | Safe | EOA `0xafA9ed53...` | EOA `0xafA9ed53...` |
| Safe `codesize` | 171 | 171 | **0** | **0** |
| Safe `getThreshold()` | 2 | 2 | reverts, no code | reverts, no code |
| `totalAssets()` at read time | 1.207273 USDC | 50,807.544626 USDC | 3.011621 USDT0 | 6.027611 USDC |
| `totalSupply()` at read time | 1.200157 | 50,533.036915 | 2.997173 | 5.997899 |
| providers | 5 (Compound, Aave, 3 Morpho) | 5 (Compound, Aave, 3 Morpho) | 1 (Aave) | 1 (Aave) |

`0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` is the deployer EOA.
`Safe` is `0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1`.

Two address facts worth recording because they look like errors and are not:

* The Monad vault proxy address equals the Plasma `ProviderManager` address. Both were
  created by the same deployer EOA at the same CREATE nonce on their respective chains,
  so `keccak(rlp([deployer, nonce]))` coincides. The Monad record was confirmed against
  Monad RPC directly: `eth_chainId` 143, `name()` "Thesauros USDC Vault", `symbol()`
  "tUSDC", and an ERC-1967 implementation slot matching
  `deployments/monad/USDCRebalancerImplementation.json`.
* The Monad ProxyAdmin `0xCf9A835467bDD83DD3169e9473Aa8e1ed1904070` matches the value
  recorded as evidence in the SEC-001 finding of 2026-08-06.

Each ProxyAdmin address also equals `ethers.getCreateAddress({from: <proxy>, nonce: 1})`,
which is the address the proxy constructor gives `new ProxyAdmin(initialOwner)`. The
upgrade script asserts that equality against the ERC-1967 admin slot before trusting
either value.

---

## 4. Fee semantics the cap raise interacts with

All of the following is read from `contracts/Rebalancer.sol` at `dev@ce1be23`, which
section 2.1 proves is the live code.

* **Rolling baseline, not a high-water mark.** `_accruedFees` charges the performance
  fee on `totalManagedAssets - $._lastTotalAssets` when that difference is positive, and
  `_applyFees` then sets `$._lastTotalAssets = totalManagedAssets` unconditionally. The
  baseline therefore moves down on a loss as well as up on a gain, and a recovery back to
  a previously-reached peak is charged again. `_highWaterMark` exists only in the
  unreleased `crosschain-sandbox` version of the contract (section 2.3).
* **Payment is dilution.** Fees are settled by `_mint(treasury, shares)`; no asset
  transfer happens at settlement. `totalAssets()` is unchanged by `applyFees()`.
* **Rounding.** `mulDiv(..., Math.Rounding.Floor)` at every step, so the treasury
  receives at most its entitlement. For a 6-decimal asset at a 25% rate,
  `yield * 0.25e18 / 1e18 == yield / 4`, so a yield of 1, 2 or 3 units settles to a zero
  fee. At the previous 20% rate the equivalent threshold was 1 to 4 units.
* **No timelock on the fee.** `setPerformanceFee` and `setManagementFee` are
  `onlyRole(ADMIN_ROLE)` and take effect in the transaction that calls them. The
  `Timelock` gates `setProviders` and `setTimelock` only.
* **Accrual settles first.** `setPerformanceFee` calls `_applyFees()` before
  `_setPerformanceFee`, so yield accrued up to that block is charged at the old rate.
* **The cap has no getter.** `MAX_PERFORMANCE_FEE` is a compile-time constant. No
  unauthenticated call distinguishes a 20% build from a 25% build, because
  `setPerformanceFee` checks the role before the cap and both builds revert
  `Unauthorized()` for a stranger. Proving the upgrade took effect relies on the
  ERC-1967 implementation slot plus a getter snapshot; observing the 25% cap directly
  requires an authenticated `setPerformanceFee(0.25e18)` from the ADMIN_ROLE holder,
  which settles accrued fees and emits events.

Interaction with the live treasury configuration:

| chain | `getTreasury()` | effect of setting a non-zero performance fee there today |
|---|---|---|
| Base | deployer EOA `0xafA9ed53...` | fee shares accrue to an EOA |
| Arbitrum | Safe, code present | fee shares accrue to a working 2-of-2 multisig |
| Plasma | Safe, `codesize == 0` | fee shares accrue to an address with no code on that chain |
| Monad | Safe, `codesize == 0` | fee shares accrue to an address with no code on that chain |

At a zero performance fee none of this is live. Raising the cap makes a 25% rate
settable, so the treasury configuration on each chain is a precondition for the
governance action that follows the upgrade, on Base through `setTreasury` and on Plasma
and Monad through SEC-019.

---

## 5. Prerequisites

### 5.1 SEC-001 (Critical, open) — ProxyAdmin owned by the deployer EOA on all four chains

Source: `.security-engineer-skill/data/reviews/2026-08-06-multichain-vault-deployment-security-review.md`,
finding `SEC-001`. Re-verified read-only on 2026-09-21: `ProxyAdmin.owner()` is
`0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` on Base, Arbitrum, Plasma and Monad
(section 3).

Mechanism, from OpenZeppelin Contracts 5.4.0 as vendored in this repository:
`TransparentUpgradeableProxy`'s constructor executes
`_admin = address(new ProxyAdmin(initialOwner))`, and
`ProxyAdmin.upgradeAndCall(proxy, implementation, data)` is `payable ... onlyOwner`
with no delay and no multisig. `deploy/deploy-usdc-vault.ts` passes
`TREASURY_ADDRESS` as `initialOwner`, and at deploy time `TREASURY_ADDRESS` equalled the
deployer EOA on all four chains, as recorded in
`deployments/*/USDCRebalancerProxy.json → args[1]`.

One key can therefore replace the code of a proxy holding user funds in a single
transaction. An upgrade performed in that state is SEC-001 being exercised.

Required before any chain is upgraded:

1. From the deployer EOA, on each chain:
   `ProxyAdmin(<admin>).transferOwnership(0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1)`.
   OpenZeppelin 5.x `ProxyAdmin` inherits single-step `Ownable`, so the transfer
   completes in that one transaction and there is no `acceptOwnership()` step.
2. Confirm `ProxyAdmin.owner()` returns the Safe on that chain.
3. Confirm the Safe can actually transact on that chain (see 5.2 for Plasma and Monad).

`scripts/upgrade-vault-implementation.ts` prints the SEC-001 status per chain, and in
execute mode it sends `upgradeAndCall` only when the configured signer is the current
`ProxyAdmin.owner()`. Once ownership has moved to the Safe, the script deploys the
implementation, prints the exact `to` / `data` / `value` for the Safe to submit as a
single contract interaction, and stops.

### 5.2 SEC-019 (High, open) — the Safe has no code on Plasma or Monad

Source: `.security-engineer-skill/data/findings/2026-09-14-plasma-monad-admin-role-unusable.md`,
finding `SEC-019`. Re-verified read-only on 2026-09-21: `codesize` of
`0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1` is 171 on Ethereum, Base and Arbitrum, and
0 on Plasma (9745) and Monad (143).

Consequence: on Plasma and Monad the Safe cannot sign, so it cannot own a ProxyAdmin,
cannot hold a usable ADMIN_ROLE, and cannot act as a treasury. SEC-001 remediation on
those two chains is blocked behind deploying the same Safe address there first.

The SEC-019 finding records that the canonical Safe infrastructure is already present on
both chains, so a deterministic CREATE2 deployment through `SafeProxyFactory` 1.4.1
`0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` against singleton 1.4.1
`0x41675C099F32341bf84BFc5382aF534df5C7461a` reproduces `0x3CDD9470...` given the same
`setup(...)` calldata and `saltNonce`. That finding also requires the predicted address be
confirmed with an `eth_call` to `createProxyWithNonce` before the deployment is sent.

Ordering that follows from 5.1 and 5.2:

* Base, Arbitrum: SEC-001 transfer, then upgrade.
* Plasma, Monad: SEC-019 (deploy the Safe at the same address), then SEC-001 transfer,
  then upgrade.

---

## 6. Upgrade procedure

The tooling is `scripts/upgrade-vault-implementation.ts`, written in the same style as
`scripts/post-deploy-handover.ts` (Hardhat runtime, `fs`-read deployment records,
environment-gated execution).

```
# read-only, no private key, nothing sent  (DRY_RUN is the default)
npx hardhat run scripts/upgrade-vault-implementation.ts --network base
npx hardhat run scripts/upgrade-vault-implementation.ts --network arbitrum
npx hardhat run scripts/upgrade-vault-implementation.ts --network plasma
npx hardhat run scripts/upgrade-vault-implementation.ts --network monad

# deploys the implementation; sends upgradeAndCall only if the signer owns the ProxyAdmin
DRY_RUN=0 npx hardhat run scripts/upgrade-vault-implementation.ts --network base
```

Verified on 2026-09-21: the dry run completes on all four networks with `.env` reduced to
`BASE_RPC_URL`, `ETHEREUM_RPC_URL` and `TREASURY_ADDRESS`, i.e. with no
`DEPLOYER_PRIVATE_KEY` present.

### 6.1 Gates the script enforces

The run aborts on any of:

| gate | condition |
|---|---|
| chain scope | `chainId == 1` |
| record vs chain | recorded implementation address differs from the ERC-1967 implementation slot |
| record vs chain | `keccak256(eth_getCode(recorded impl))` differs from `keccak256(record.deployedBytecode)` |
| proxy admin identity | ERC-1967 admin slot differs from `getCreateAddress({from: proxy, nonce: 1})` |
| proxy admin version | `UPGRADE_INTERFACE_VERSION()` differs from `"5.0.0"` |
| storage layout | recorded `storageLayout` JSON differs from the new build's |
| ERC-7201 slots | any `*StorageLocation` constant differs, moves or disappears |
| source scope | any file in the `Rebalancer` compilation unit other than `contracts/libraries/Constants.sol` differs from the recorded live build |
| no-op | nothing at all differs |
| cap value | the live line is not `uint256 constant MAX_PERFORMANCE_FEE = 0.2 * 1e18; // 20%` or the new line is not `uint256 constant MAX_PERFORMANCE_FEE = 0.25 * 1e18; // 25%` |
| management cap | `uint256 constant MAX_MANAGEMENT_FEE = 0.05 * 1e18;` absent from either build |
| ABI | any selector present in the live ABI is absent from the new one |
| reinitializer | `initializeV2()` exists in the new build, which would require non-empty `upgradeAndCall` data |
| deployed code | after deployment, `keccak256(eth_getCode(new impl))` differs from the local artifact |

The source gate is scoped to the `Rebalancer` compilation unit, i.e. the import graph in
`buildInfo.input.sources` for `contracts/Rebalancer.sol:Rebalancer`. That is exactly the
set of sources whose content can change the implementation bytecode. This was tested:
adding a comment to `contracts/Rebalancer.sol` makes the script abort with
`source changed outside the allowed set [contracts/libraries/Constants.sol]`, while a
change to `contracts/access/Timelock.sol`, which is outside that graph, correctly does not
affect the gate.

### 6.2 Sequence per chain

1. Close SEC-001 (and SEC-019 first on Plasma and Monad). Re-run the dry run and confirm
   it reports `SEC-001 remediated (ProxyAdmin owned by the governance Safe)`.
2. Dry run and record the printed evidence: source diff, storage layout, ABI comparison,
   the getter snapshot, ProxyAdmin address and owner.
3. `DRY_RUN=0` to deploy the implementation. It is recorded as
   `deployments/<chain>/USDCRebalancerImplementationV2.json`; the existing
   `USDCRebalancerImplementation.json` stays in place so the old build remains diffable.
   Explorer verification runs unless `SKIP_VERIFY=1` or `ETHERSCAN_API_KEY` is absent.
4. Submit the upgrade from the ProxyAdmin owner:
   `to=<ProxyAdmin>`, `data=upgradeAndCall(<proxy>, <newImpl>, 0x)`, `value=0`.
   `upgradeAndCall` is `payable` and requires `msg.value == 0` when data is empty.
5. The script's execute path re-reads the ERC-1967 implementation slot, confirms the
   admin slot is unchanged, re-takes the getter snapshot and fails on any drift outside
   `lastTimestamp`, `totalAssets`, `totalSupply` and the vault's own dead shares.
6. Confirm on the explorer that the new implementation address is verified with source
   whose `Constants.sol` shows `0.25 * 1e18`.

`version()` and `initializeV2()` are absent from this generation (57 selectors, neither
present), so the implementation slot plus the snapshot is the proof of upgrade, and
`upgradeAndCall` data is `0x`.

### 6.3 Suggested ordering

Base carries 1.207273 USDC and has a working Safe, which makes it the cheapest canary.
Arbitrum carries the material balance (50,807.544626 USDC) and already has a
Safe-owned Timelock. Plasma and Monad follow once SEC-019 is closed. Each chain is an
independent upgrade: one implementation deployment and one `upgradeAndCall` per chain,
with no cross-chain dependency in the contracts.

### 6.4 Setting the fee

The upgrade only widens what `setPerformanceFee` accepts. Charging 25% is a separate
ADMIN_ROLE transaction per chain, and before it is sent on a given chain that chain's
`getTreasury()` should be an address that can act there: Base requires `setTreasury` to
the Safe, Plasma and Monad require SEC-019. Arbitrum is already configured with the Safe
as treasury.

---

## 7. Test evidence

### 7.1 New tests

`test/unit/PerformanceFeeCap.t.sol`, 17 tests, fork-free, self-contained doubles
(`FeeCapAsset`, `FeeCapSource`, `FeeCapProvider`) modelled on the delegatecall discipline
documented in `IProvider`: the provider holds no mutable storage because `deposit` and
`withdraw` execute inside the vault's context.

| area | tests |
|---|---|
| the constant | `testMaxPerformanceFeeIs25Percent`, `testMaxPerformanceFeeFitsTheUint96StorageField`, `testMaxManagementFeeCapIsUnchanged` |
| cap enforcement | `testSetPerformanceFeeAtCapSucceedsFromAdminRole`, `testSetPerformanceFeeOneAboveCapRevertsInvalidInput`, `testSetPerformanceFeeAtUint96MaxRevertsInvalidInput`, `testSetPerformanceFeeAtOldCapStillSucceeds`, `testSetPerformanceFeeWithoutAdminRoleReverts`, `testInitializeAtCapSucceeds`, `testInitializeOneAboveCapReverts` |
| management cap unchanged | `testSetManagementFeeAtCapStillSucceeds`, `testSetManagementFeeOneAboveCapStillReverts` |
| accrual at 25% | `testPerformanceFeeAccrualAtCapWorkedExample`, `testAccrualAtNewCapExceedsOldCapOnIdenticalInputs`, `testFuzzPerformanceFeeAccrualAtCap(uint256,uint256)`, `testPerformanceFeeAtCapFloorsToZeroBelowFourUnits`, `testPerformanceFeeAtCapUsesRollingBaselineNotHighWaterMark` |

The worked example pins exact integers: seed 1e6 dead shares, a 1,000e6 deposit, 100e6
of yield, giving `feeAssets = 25,000,000`, `feeShares = 25,000,000 * 1,001,000,000 /
1,076,000,000 = 23,257,434` (floor, remainder 1,016), treasury redeemable value
`24,999,999`, `totalAssets` unchanged at `1,101,000,000`, and every share class's claim
summing back to `totalAssets` within 4 units. The fuzz test re-derives
`_accruedFees`'s performance leg and compares against `getAccruedFees()` before
settlement and `balanceOf(treasury)` after it.

### 7.2 Negative control

With `MAX_PERFORMANCE_FEE` restored to `0.2 * 1e18`, 5 of the 17 new tests fail:
`testMaxPerformanceFeeIs25Percent`, `testPerformanceFeeAccrualAtCapWorkedExample`
(`previewed performance fee shares: 18519888 != 23257434`),
`testAccrualAtNewCapExceedsOldCapOnIdenticalInputs`,
`testFuzzPerformanceFeeAccrualAtCap`, and
`testPerformanceFeeAtCapUsesRollingBaselineNotHighWaterMark`. The constant was then set
back to `0.25 * 1e18`. The remaining 12 assert the enforcement mechanism rather than the
number, so they hold under either cap by design.

### 7.3 Suite results

| command | result |
|---|---|
| `forge test` on unmodified `dev@ce1be23` (baseline, before this change) | 7 suites, 34 passed, **1 failed**, 0 skipped (35 tests), 41.2s |
| `forge test` after the change | 8 suites, 51 passed, **1 failed**, 0 skipped (52 tests), 37.8s |
| `forge test --no-match-path "test/forking/NewVaultWithdraw.t.sol"` after the change | 7 suites, **51 passed, 0 failed, 0 skipped**, 36.9s |
| `forge test --match-path test/unit/PerformanceFeeCap.t.sol --fuzz-runs 5000` | 17 passed, 0 failed |
| `npx hardhat test` | `0 passing` — no Hardhat/Mocha test files exist at `dev@v0.9.3`; `test/` contains only `*.sol` |

Both runs used `BASE_RPC_URL` and `ETHEREUM_RPC_URL` from `.env`. 51 − 34 = 17, the new
unit tests; the fork suites are unchanged in count and outcome.

The single failure is `test/forking/NewVaultWithdraw.t.sol:testWithdrawTrace()`. It is
unchanged by this diff and fails identically before it. It reads `VAULT` and
`DEPLOYER_ADDR` from the environment, so a plain `forge test` fails with
`vm.envAddress: environment variable "VAULT" not found`. Supplying
`VAULT=0x3C7739173cca612B6394EE57131458185A5beC44` and
`DEPLOYER_ADDR=0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D` makes it fail instead with
`ERC20InsufficientBalance(0xafA9ed53..., 260, 994105)`: the address holds 260 shares and
the test tries to withdraw 1e6 assets. It is a one-off manual trace script, and
`.github/workflows/security.yml` runs Slither and `npm audit` only, so no CI gate depends
on it.

No test was skipped for missing credentials: `BASE_RPC_URL` and `ETHEREUM_RPC_URL` are
present in `.env` and every fork test ran against them.

### 7.4 Static analysis

`slither contracts --filter-paths "node_modules|lib|test"` on 2026-09-21 analysed 72
contracts with 102 detectors and reported 79 results. The highest-severity hit is
`arbitrary-send-erc20` at `contracts/utils/VaultFactory.sol:65`
(`asset_.safeTransferFrom(seedOwner_, address(this), seedAmount_)`, preceded at
`VaultFactory.sol:53-55` by `if (msg.sender != seedOwner_) { revert NotSeedOwner(); }`);
`arbitrary-send-erc20` is
a High-impact detector, so the `fail-on: high` job in `.github/workflows/security.yml`
trips on it at `dev@v0.9.3` as well.

Every file Slither reported on is unchanged by this diff:
`contracts/Rebalancer.sol`, `contracts/access/AccessManager.sol`,
`contracts/access/Timelock.sol`, `contracts/interfaces/IPausableActions.sol`,
`contracts/interfaces/morpho/IMetaMorpho.sol`, `contracts/providers/AaveV3Provider.sol`,
`contracts/providers/MorphoProvider.sol`, `contracts/utils/PausableActions.sol`,
`contracts/utils/VaultFactory.sol`. `contracts/libraries/Constants.sol`, the only file
this change touches, appears nowhere in the report. `git diff --stat dev -- contracts/`
is `contracts/libraries/Constants.sol | 2 +-`, one insertion and one deletion, so the
Slither result set is identical to the pre-change baseline by construction.

---

## 8. Out of scope

| item | why, and where it lives |
|---|---|
| **Dolomite provider adapter** | `contracts/providers/` at `dev@v0.9.3` contains `AaveV3Provider.sol`, `CompoundV3Provider.sol` and `MorphoProvider.sol` only. `git grep -i dolomite` returns nothing in any `.sol` or `.ts` file on `dev`, `main` or `crosschain-sandbox`. Dolomite adapters live in a different repository, `Rebalance_finance/lending-contracts-simulations/contracts/providers/DolomiteProvider.sol`. |
| **Spark provider adapter** | No file under `/Users/ivanborisov/Desktop/thesauros.io` matches `spark` in any `.sol` source. There is no Spark adapter in this repository or in any sibling one. |
| **Ethereum mainnet VaultFactory path** | `contracts/utils/VaultFactory.sol` and the `chainId === MAINNET_CHAIN_ID` branch of `deploy/deploy-usdc-vault.ts` deploy a new vault atomically; they are not an upgrade path and no mainnet proxy of this generation exists. `deployments/ADDRESSES.md` records the mainnet vault `0x839E57080C18195D8D343a02c2f623b5916f7383` as a legacy generation compiled with solc 0.8.23 whose `getTimelock`, `getTreasury`, `getManagementFee`, `getPerformanceFee`, `getMinAssets` and `getEntryProvider` all revert, deliberately left untouched by decision of 2026-09-12. The upgrade script refuses `chainId == 1`. |
| **Crosschain Mesh contracts** | `contracts/crosschain/**` (`MeshProvider`, `MeshNode`, `MeshCustodian`, `CCTPMeshBridgeAdapter`, `CCTPRelayReceiver`, `ITokenMessengerV2` and their interfaces) exists only on `crosschain-sandbox`; `git ls-tree dev contracts/crosschain` is empty. |
| **Findings 1 to 8 hardening** | The commits in section 2.3, including `VaultDeployer.sol`, the `Rebalancer.sol` rewrite (+302/−34), `initializeV2()`, `_highWaterMark` and the Timelock zero-address check. Reaching the live generation with any of them is a separate change and a separate review. |
| **Timelock, ProviderManager, the provider adapters** | Byte-identical to `dev@ce1be23`; only the vault implementation is upgraded. Their ownership state is reported in section 3 because it bears on governance, and changing it is separate work. |
| **Setting a non-zero fee** | This diff changes what `setPerformanceFee` accepts. Calling it is a governance action, per chain, with the treasury preconditions in section 6.4. |
| **`tron_connector` and `legacy_dev` branches** | Separate generations, not reachable from `dev`. |

---

## 9. Reproducing every claim above

```bash
cd optimized-rebalancer-contracts
git switch dev && git rev-parse HEAD v0.9.3^{commit}            # ce1be23... twice
git merge-base --is-ancestor b84b14a08c8f49a6d881a12c0a5e3547b84b21dd dev; echo $?   # 1
git diff --numstat dev crosschain-sandbox -- contracts/Rebalancer.sol                # 302  34
git log --all -S 'MAX_PERFORMANCE_FEE = 0.2 * 1e18' -- contracts/libraries/Constants.sol

# bytecode identity of the live generation
git switch dev && npx hardhat compile
python3 -c "import json,hashlib;b=json.load(open('artifacts/contracts/Rebalancer.sol/Rebalancer.json'))['deployedBytecode'];print(hashlib.sha256(bytes.fromhex(b[2:])).hexdigest())"
python3 -c "import json;d=json.load(open('deployments/base/USDCRebalancerImplementation.json'));print(d['deployedBytecode'][:20], json.loads(d['metadata'])['settings'])"

export PATH="$PATH:$HOME/.foundry/bin"
cast codehash 0xd4aC8Bcec0790ADDa563dB1B35c072B485fE2708 --rpc-url https://base-rpc.publicnode.com
cast storage 0x3C7739173cca612B6394EE57131458185A5beC44 \
  0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 \
  --rpc-url https://base-rpc.publicnode.com
cast codesize 0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1 --rpc-url https://rpc.plasma.to   # 0
cast codesize 0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1 --rpc-url https://rpc.monad.xyz  # 0

# tests
set -a && . ./.env && set +a
forge test --no-match-path "test/forking/NewVaultWithdraw.t.sol"
forge test --match-path test/unit/PerformanceFeeCap.t.sol --fuzz-runs 5000

# upgrade tooling, read-only
npx hardhat run scripts/upgrade-vault-implementation.ts --network base
```

`cast keccak` reading hex from stdin does not decode it as bytes, so it reports a
different digest from `keccak256` over the code. Use `cast codehash <addr>` or
`ethers.keccak256(hex)` for the values quoted in section 1 and section 2.1.

---

## 10. Files changed on `feat/fee-cap-25`

| file | change |
|---|---|
| `contracts/libraries/Constants.sol` | `MAX_PERFORMANCE_FEE` `0.2 * 1e18` to `0.25 * 1e18` |
| `.env.example` | the `PERFORMANCE_FEE_PERCENT` comment now states the 25% maximum |
| `test/unit/PerformanceFeeCap.t.sol` | new, 17 fork-free tests covering the cap and accrual at 25% |
| `scripts/upgrade-vault-implementation.ts` | new, dry-run-by-default upgrade tooling with the gates in section 6.1 |
| `audit/scope-2026-09-fee-cap-25.md` | this document |

`scripts/` and `SECURITY_AUDIT.md` are listed in `.gitignore` at `dev@v0.9.3`, so the
script is committed with `git add -f` and shows up in `git status` as untracked
otherwise. No contract logic outside `Constants.sol` was modified, and no deployment
record under `deployments/` was touched.
