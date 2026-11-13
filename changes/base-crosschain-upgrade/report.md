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

Rebalancer source is verified on Basescan (Solidity 0.8.33, optimizer 200,
Paris) from the recorded build input; the two providers were submitted the same
way and were still in the Basescan queue at the time of writing.

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

## Remaining steps

1. After `2026-11-14T10:43:34Z` execute the three queued operations in order,
   registration first and then both caps, keeping the executor quiescent until
   all three succeed.
2. Add `FluidProvider` and `GauntletPrimeV2MorphoProvider` to
   `deployments/base/crosschain.json` with their codehashes and deploy txs. The
   manifest keys are what `strategyProviders` resolves the two labels from.
3. Re-run phase 4; both provider labels must resolve and the pinned sources must
   match the registry.
4. Confirm fresh complete NAV and exits before any allocation into either new
   venue, and ship the compatible remote ops release. Caps are ceilings, not
   target allocations.

