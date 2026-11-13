# Base: Strategy upgrade, Fluid and Gauntlet Morpho V2

Change: `base-crosschain-upgrade`. Requirements: `specs/base-crosschain-upgrade/spec.md`.
This release targets only the existing Base cross-chain Strategy
`0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33`, chain 8453. It preserves the hub
vault, accountant, agent, current entry and the five existing provider positions.
Arbitrum and Ethereum configuration is not expanded by this release.

| Appended venue | Immutable source | Proposed maximum share |
| --- | --- | --- |
| Fluid fUSDC | `0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169` | 30% |
| Gauntlet USDC Prime Morpho V2 | `0x050cE30b927Da55177A4914EC73480238BAD56f0` | 20% |

Fluid provenance: [official Base deployment](https://github.com/Instadapp/fluid-contracts-public/blob/main/deployments/base/fToken_fUSDC.json).
Both sources must report native Base USDC. These are proposed release ceilings,
not target allocations or an authorization to move capital. The preparation CLI
requires both caps explicitly; it never silently treats a missing cap as uncapped.
The original Gauntlet Core Morpho V1 provider remains registered and funded.

## Build and prepare

Use the committed lockfiles, submodules, Solidity 0.8.33 and optimizer 200.

```sh
FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile
npm run test:deploy
npm --prefix ops run typecheck
npm --prefix ops test
BASE_RPC_URL=https://mainnet.base.org npm run prepare:base-crosschain -- --out out/base-upgrade-draft
```

The last command exits 2 with a useful `DRAFT_NOT_SIGNABLE` bundle: pinned live
identity/source observations and constructor transactions for Rebalancer,
FluidProvider and MorphoV2Provider. It contains no guessed deployment addresses
or executable upgrade/governance calls. It does not read signer keys, create a
wallet, sign or broadcast. Reuse a private read RPC through `BASE_RPC_URL` if the
public endpoint cannot serve the required state. The output path must be new.

Before producing a concrete upgrade bundle, provide all of:

- Actual deployed implementation and provider addresses, verified against the
  current build and their immutable sources.
- Governance-attested historical HWM, its provenance, and confirmation of the
  existing sources. The old implementation does not store historical HWM; a
  current PPS used in a fork test is not evidence of the historical maximum.
- Acceptance that migration waives unsettled legacy fees and resets the fee
  baseline. Recheck accrued fees immediately before execution.
- Reviewed explicit caps, a compatible remote ops release, fresh NAV and gas
  funding for deployment, upgrade, governance and Base L1 data fees.

The CLI accepts `--implementation`, `--fluid-provider`, `--morpho-v2-provider`,
`--historical-hwm`, `--attest-historical-hwm`, `--attest-provider-sources`,
`--hwm-evidence`, `--sources-evidence`, `--accept-legacy-fee-waiver`,
`--fluid-cap-bps` and `--morpho-v2-cap-bps`.
Do not pass an attestation flag without its underlying evidence. All preparation
remains unsigned even when inputs are complete. Refresh a complete plan before
signing: PPS, authorities, provider state, gas and Timelock ETA can change.

## Staged release

1. Verify the running ops revision and roll out a compatible image that includes
   `strategy-value.ts`. Confirm a fresh accepted Tick. Stop competing allocation,
   rebalancing and provider/governance changes for the reviewed transition.
2. Deploy and verify the three candidate contracts using the bundle's creation
   data. These deployments alone do not change the live proxy or provider list.
   Regenerate preparation with their actual addresses and reviewed migration inputs.
3. Execute the actual ProxyAdmin owner's `upgradeAndCall` with
   `initializeSecurityAccounting(historicalHwm)` encoded as migration calldata.
   Never use an empty-data upgrade or the old fee-cap-only upgrade script.
4. Queue `setProviders` with the original five followed by Fluid and V2, and
   both new caps, using the exact tuples and the actual Timelock delay (currently
   24 hours on the stand). Preserve original queue tuples for execute/cancel.
5. After the delay execute registration, then both caps **before any new-venue
   allocation**. `setProviderCap` requires registration first. A Safe can batch
   these executions atomically; an EOA must keep the executor quiescent until all
   three succeed. Do not infer atomicity from a JSON list of transactions.
6. Publish a manifest with the actual `StrategyImplementation`, `FluidProvider`,
   `GauntletPrimeV2MorphoProvider`, deployment txs and runtime codehashes. Preserve
   proxy addresses and the old implementation provenance. Deploy the matching ops
   configuration and run phase 4/monitor against the actually deployed network set.
7. Confirm seven unique sources, unchanged entry/old caps/roles/fees/holdings,
   initialized HWM and source pins. Verify fresh NAV, allocate/deallocate,
   return-to-vault and a user exit. Only then perform reviewed small allocations
   into each new venue and verify a full withdrawal before raising exposure.

No live manifest is changed by preparation. Between registration and publishing
the final manifest, keep a consistent candidate manifest on the operator's
release workspace and do not mislabel missing-provider monitor checks as healthy.
Phase 1 supports the seven providers for a new deployment but does not upgrade
an existing Strategy. Phase 5 does not register providers; this Base preparation
tool owns the scoped provider expansion, without scheduling other networks,
buffer changes or unrelated protocol parameters.

## Verification and rollback

`test/forking/BaseStrategyExpansion.t.sol` exercises the actual deployed Base
proxy, local atomic migration, delayed registration, preserved positions/caps
and new venue round trips. Run against a pinned Base archive block:

```sh
BASE_RPC_URL=<archive-read-rpc> BASE_FORK_BLOCK=<reviewed-block> forge test --match-path test/forking/BaseStrategyExpansion.t.sol -vv
```

No URL means an explicit skipped fork suite, not live verification. Local fork
HWM values and funded test accounts are simulation inputs only.

`test/forking/BaseStrategyPayout.t.sol` additionally exercises the actual Base
hub's fresh-Tick gate, push/recall and real-holder instant payout with both new
venues funded. Its authorized snapshot uses actual Base holdings and an
explicitly modeled remote value and simulated local block references. It does
not re-derive Arbitrum NAV or attest the remote services. Fresh-Tick checks stay
enabled: the stale post-governance Tick must reject instant exits before the new commit.

Before execution, cancellation is the exact Timelock `cancel` tuple from the
bundle. After initialization, do not blindly restore legacy bytecode: the new
security state persists and new providers may hold assets. Stop allocations,
unwind each new venue, check full receipt balances and claims, retain every
funded provider, then rehearse a forward recovery. A failure of a provider NAV
read remains fail-closed; this release does not change that financial policy.

ProviderManager and CCTP adapter replacements are separate migrations. They are
not installed by this Strategy upgrade, and no bridge endpoint is switched here.
