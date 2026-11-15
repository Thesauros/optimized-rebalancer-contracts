# Base cross-chain Strategy release branch

Change: `base-crosschain-upgrade`. Base: main `32f7dcf`.
Branch: `feat/base-crosschain-upgrade`.

QA and Security: PASS for the prepared Base branch. The Base stand release has
been executed on mainnet: candidates deployed, proxy upgraded, governance
queued. See the execution record below for what remains.

Implemented the three requested Base capabilities in one branch: preparation of
the existing Strategy's current Rebalancer upgrade, Fluid fUSDC, and Gauntlet
USDC Prime Morpho V2. The original five providers remain in their existing order
and the Aave entry is retained. New proposed ceilings are Fluid 3000 bps and
V2 2000 bps; the unsigned planner requires explicit matching reviewed inputs.
No capital allocation is implied by these ceilings or provider registration.

The contracts already in main implement the target behavior. This branch adds
Base sources, fresh deployment integration, a scoped unsigned upgrade/governance
planner, source-aware monitor checks, regression/fork coverage and an operator
runbook. EpochVault, TickAccountant, ChainAgent, ProviderManager, CCTP endpoints
and live deployment manifests are not replaced by this scoped change. No other
network is added or activated.

## Evidence

| Check | Result |
| --- | --- |
| Hardhat compile | 88 Solidity files, Paris, Solidity 0.8.33, optimizer 200 |
| Solidity non-fork regression and invariants | 199 passed, zero failed/skipped |
| Actual-state Base expansion fork | 6 passed, zero failed/skipped at block 55,863,000 |
| Additional actual Base hub payout path | 1 passed, zero failed/skipped, with modeled remote NAV |
| Full ops suite including seven-provider valuation | 102 passed, zero failed/skipped |
| Seven-provider valuation / fee and failure suite | 9 passed, zero failed/skipped |
| Deployment/preparation suite | 34 passed, zero failed/skipped after final guards |
| Ops and preparation-script typechecks | passed |
| Live constructor-only preparation | DRAFT_NOT_SIGNABLE; current source identities and candidate constructor simulations verified |

Reproduction commands and staged release instructions are in
`docs/base-crosschain-upgrade.md`. Evidence:
`base-expansion-fork-verification.json`, `hub-payout-verification.json`,
`preparation.json`, `qa.md` and `security.md` in this directory.

The hub payout test intentionally models the unchanged remote leg and local
block references. It does not attest full cross-chain NAV re-derivation or the
running server image. Real Base contracts enforce the stale-Tick gate before
an authorized fresh snapshot is committed, and both new venues are funded.
No freshness/risk limit is bypassed to obtain a successful payout.

The live bundle has no guessed addresses or fabricated historical HWM. Missing
actual deployments, governance HWM/source evidence, fee-waiver acceptance and
reviewed caps suppress all upgrade/governance calldata. Complete unsigned
preparation still requires fork/human review and separately approved execution.

## Execution record

Executed on Base mainnet (chain 8453, `stand` profile) on 2026-11-13 from
`0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D`, which holds ProxyAdmin ownership,
Timelock ownership, ADMIN_ROLE, EXECUTOR_ROLE and the treasury on this stand.
The governance decisions behind the release inputs were taken by the founder in
the same session: registry caps, ceiling-PPS high-water mark, legacy fee waiver.

Candidates were deployed from the reviewed creation data. Before each broadcast
`keccak256(creationData)` was required to equal the reviewed `creationCodeHash`;
after each receipt `keccak256(runtime)` was required to equal the reviewed
`expectedRuntimeHash`. Both held for all three. Record:
`base-candidate-deployment.json`.

| Contract | Address | Deploy tx | Block | Gas | Runtime hash |
| --- | --- | --- | --- | --- | --- |
| Rebalancer implementation | `0x6909E3654B060f8D1507F4fE8c71B604cA79eb2D` | `0x853eb4522a492e1e9b55bb27e6ddfb6b391a1311c3df25fcc5ba6eed826de2ba` | 56857976 | 4963781 | `0x6a9f9388ac52` |
| FluidProvider | `0x7ca72c28Aec15c359cC1e9cFc3021519D02E1304` | `0xdd951cfbd296db61fcba6130b665f3ce681b11feeaca13ec0926751804b1c89a` | 56857984 | 638097 | `0x5414d072553e` |
| MorphoV2Provider | `0x23bbE424F1B621229c6A237F93D4234B646cf6e7` | `0xe095680a9363bbeb0db474ad2f76b7ab4525484df5b8d0a2d324a1f5a21de457` | 56857994 | 1879342 | `0x5e09a5d4f8bb` |

Bytecode identity was re-proved independently of any explorer: for all three
contracts, an `eth_call` with no `to` and `data = artifact.bytecode ++
abi-encoded constructor args` returns runtime code byte-identical to
`getCode(address)` on Base, with keccak `0x6a9f9388ac52…`, `0x5414d072553e…` and
`0x5e09a5d4f8bb…`. Both providers carry an immutable `source`, so their on-chain
runtime legitimately differs from the `build-info` `deployedBytecode` template by
exactly the immutable slots; the constructor simulation, not a template hash
comparison, is the correct check.

All three sources are verified on Basescan (Solidity 0.8.33, optimizer 200,
Paris), submitted through `hardhat verify --network base` with
`FOUNDRY_AUTO_DETECT_REMAPPINGS=false` and confirmed through the Etherscan V2
`getsourcecode` endpoint. Hand-rolled standard-json submissions of the same
build input were rejected by the explorer with a parser error for both
providers, so the plugin path is the one that works here.


Attested release inputs used by the planner:

| Input | Value |
| --- | --- |
| Historical HWM | `1005629483841248682` = ceiling PPS at the plan block plus 6 ppm, one hour of measured accrual |
| HWM basis | 1101 hourly archive samples from block 51905747 to 56854291; PPS never decreased, sampled maximum equals head, unsampled bound 6 ppm (`hwm-evidence.json`) |
| Caps | Fluid 3000 bps, GauntletPrimeV2Morpho 2000 bps, the registry values |
| Legacy fee treatment | Waiver accepted; both fees were 0 at execution |

Atomic upgrade `ProxyAdmin.upgradeAndCall` with
`initializeSecurityAccounting(1005629483841248682)`: tx
`0x5b256b18578f55624a7daaf4c88cd239f965aa1deb1d7faed31ebc0202b7de80`, block
56864845, gas 425061, implementation `0xfcE142db5FD78F64c97b04d9a587E2C53341b910`
to `0x6909E3654B060f8D1507F4fE8c71B604cA79eb2D`. The exact reviewed calldata was
simulated once more immediately before the broadcast. 67 pre- and post-conditions
passed, pinned to the upgrade block: totalSupply unchanged at 19800478,
totalAssets drift 0 ppm, the five providers and their order, entry, caps and now
pinned sources preserved, fees, treasury, timelock, asset and roles preserved,
EpochVault/TickAccountant/ChainAgent implementations untouched, both new venues
still unregistered and uncapped. Record: `base-upgrade-execution.json`.

Governance queued in the Timelock (delay 86400, ETA `2026-11-14T10:43:34Z`), all
three confirmed `queued` on-chain:

| Operation | Queue tx | Transaction id |
| --- | --- | --- |
| `setProviders(address[])`, seven providers | `0x71064d0a9cf341c8f9ec3de49b92e2c1191ea12bdd31c316f1457062e399f848` | `0x11dd36bae1392dec686f294c754ef144c8a6a7a6d1445a0592d2ae4208efbbed` |
| `setProviderCap(Fluid, 3000)` | `0xac59122bd622a3aa237156845675318e9bd602062e39016bb35a7885ac780ce5` | `0x7d6b5d2bfb0591f615b9f289daa86dc5c481ccecc4591de8e17b275e28db20fb` |
| `setProviderCap(GauntletPrimeV2Morpho, 2000)` | `0x0c3edcbeb2ee160c057a973e7dd06675fa1aca4ff5e9e5488894d44a07d78857` | `0xeaae620d222ac1f0e2b2d129383afb4ada0adb638137bcfcf25aa7098de7c7c2` |

`deployments/base/crosschain.json` now records the new implementation address,
codehash and deploy tx. Phase 4 read-only verification after that update reports
62 of 67 checks. The two `strategy provider manifest` failures for Fluid and
GauntletPrimeV2Morpho are the designed pre-activation state: the labels become
resolvable only once the providers are in the manifest, which happens with
registration. The remaining three are pre-existing stand gaps this change does
not touch: `route base->arbitrum` parameters, a missing
`deployments/mainnet/crosschain.json` peer manifest, and a TickAccountant chain
set of (8453, 42161) against the wider registry network list.

Operator tooling is kept in the branch so the executed bytes are reproducible:
`scripts/sample-base-pps-history.mjs` builds the HWM archive sample,
`scripts/deploy-base-candidates.ts` broadcasts the reviewed creation data,
`scripts/execute-base-upgrade.ts` runs the pre-flight, the upgrade and the
queue, and `scripts/execute-base-governance.ts` executes the queued operations
once the delay has elapsed. All of them read the committed bundle
`base-upgrade-plan.json` and broadcast its calldata verbatim; none derives an
address, a cap or a mark on its own. Each refuses to send unless the reviewed
runtime and creation hashes still match, and each writes its own evidence file
into this directory.

## Governance execution record

The three queued operations were executed on 2026-11-15T14:52Z, inside the
grace period that runs to 2026-11-28T10:43:34Z, in the reviewed order and from
the same EOA. Each was simulated with `eth_call` immediately before it was sent,
and the executor was left quiescent across all three.

| Operation | Tx | Block | Gas |
| --- | --- | --- | --- |
| `setProviders(address[])`, seven providers | `0x7b92c38db9dc25ced0a5f4bdb4f2c000ba7353ae6f36d524ff0c984d03e127ee` | 57819761 | 349784 |
| `setProviderCap(Fluid, 3000)` | `0xcc08b0451fcef55f1c114857c370b5bb6d4096f73b98df081d80d793be1db0ca` | 57819771 | 84541 |
| `setProviderCap(GauntletPrimeV2Morpho, 2000)` | `0x7305965b74d240e2e6c87ac4258671206666b2e6d31e9546c2daf45128ef21d1` | 57819784 | 86929 |

All three `queued` flags cleared, which is the Timelock's own record that they
ran. 48 post-conditions passed, pinned to the last execution block: seven
providers with the five legacy ones unchanged in place and order, entry still
Aave uncapped, legacy caps still 0/5000/4000/3000/4000, Fluid 3000 and
GauntletPrimeV2Morpho 2000, pinned sources matching the registry for both new
venues and unchanged for the five legacy ones, high-water mark still
`1005629483841248682`, fees 0/0, treasury, timelock, asset and ADMIN preserved,
`providersHealthy` true, totalSupply unchanged at 19800478 and totalAssets drift
0 ppm. Record: `base-governance-execution.json`.

The same run added `FluidProvider` and `GauntletPrimeV2MorphoProvider` to
`deployments/base/crosschain.json` with their codehashes and deploy txs.

Phase 4 re-run afterwards reports 68 of 71 checks, up from 62 of 67 before
registration. Both `strategy provider manifest` labels now resolve, both caps
match the registry and both pinned sources match. The three remaining failures
are the same pre-existing stand gaps recorded above and are unchanged by this
release: `route base->arbitrum` parameters, the missing
`deployments/mainnet/crosschain.json` peer manifest, and the TickAccountant
chain set (8453, 42161).

## Downstream consumers

Checked after the upgrade. `thesauros-app` and `developer.thesauros.io` do not
reference the stand at all. `developer-portal/lib/crosschain-config.mjs` pins
`EpochVaultImplementation` and `EpochVaultLogic`, both untouched here, and reads
providers dynamically, so nothing in it went stale; the two new venues were added
to the `PROVIDERS` name map in `lib/insights.mjs`, pushed to branch `migration`
as `71ef66a` after a rebase over two commits that landed there meanwhile.

`thesauros_monitoring_service` needed a real fix. `venueTypeFromIdentifier`
matched `Morpho_V2_Provider` on the bare `morpho` substring and sent it through
the V1.1 curator withdraw-queue read, which describes a different contract: the
result would have been a plausible capacity figure computed from the wrong
chain of contracts. Both families now have their own type and their own reader
(commits `38b816e` and `8b5a671`, master). Live Base reads: Gauntlet USDC Prime
294,272,016 USDC across 6 of 6 markets, Fluid fUSDC 732,983 USDC in the
Liquidity layer against a 6,012,610 USDC fToken claim. The monitoring service
has not been redeployed, so the running instance still carries the old mapping.

## Remaining steps

1. Redeploy the monitoring service. The fix is on `master` but the running
   instance still carries the old venue mapping, so until it is redeployed a
   position in Morpho Vault V2 would be measured with curator-vault math.
2. Confirm fresh complete NAV and exits before any allocation into either new
   venue. NAV still needs `ops/.env.server`, which this checkout does not have.
   Caps are ceilings, not target allocations.
3. Rotate governance off the single EOA before real TVL, per
   `deploy/crosschain/06-rotate-governance.ts`. Phase 4 flags it as allowed for
   the stand profile. The same EOA carries an EIP-7702 delegation to a
   Safe-1.3.0-compatible implementation whose storage is empty and whose
   `setup` simulation reverts, so the delegation is inert and the trust root is
   one key; that deserves its own look.
4. Pre-existing stand gaps surfaced by phase 4 and untouched by this release:
   `route base->arbitrum` parameters, the missing
   `deployments/mainnet/crosschain.json` peer manifest, and the TickAccountant
   chain set (8453, 42161).
5. Merge decision. The branch contains `origin/main` and `origin/dev` in full, so
   either merge is a fast-forward.

