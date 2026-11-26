# Arbitrum: Strategy upgrade, Fluid and Gauntlet Morpho V2

Change: `arbitrum-crosschain-upgrade`. Requirements:
`specs/arbitrum-crosschain-upgrade/spec.md`. Research:
`changes/arbitrum-crosschain-upgrade/research.md`.

This release prepares only the existing Arbitrum cross-chain Strategy
`0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71`, chain ID **42161**. Preserve
its five current providers, Aave entry, existing positions and economic settings;
append two separately deployed provider adapters. The local ChainAgent is
preserved. Base's EpochVault, EpochVaultLogic, TickAccountant, Strategy and
ChainAgent are outside this upgrade and remain unchanged.

| Proposed addition | Underlying source on Arbitrum | Proposed provider cap |
| --- | --- | --- |
| Fluid fUSDC | `0x1A996cb54bb95462040408C06122D45D6Cdb6096` | 3000 bps / 30% |
| Gauntlet USDC Prime Morpho V2 | `0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78` | 2000 bps / 20% |

The three candidates were deployed on 25 November 2026. Use their recorded
addresses for the implementation and provider inputs when preparing the
governance bundle. [Candidate addresses and transaction receipts](../changes/arbitrum-crosschain-upgrade/candidate-deployments.json)

Both sources use native Arbitrum USDC
`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, with six asset decimals.
The table identifies the underlying sources. The deployed adapters are
`FluidProvider(fUSDC)` and `MorphoV2Provider(GauntletPrimeV2)` on Arbitrum.
Use their verified deployed addresses in `setProviders`. Do not reuse
Base adapter addresses, insert underlying vaults directly, or replace the
existing Gauntlet Core Morpho V1 position.

The proposed caps match Base's release ceilings; they are not target allocations
or an Arbitrum execution decision. Preparation requires both caps explicitly.
Changing a proposal requires reviewing and updating the registry before generating
a complete bundle. Missing inputs never silently become uncapped venues.

## Build and unsigned preparation

Use the committed lockfiles/submodules, Solidity 0.8.33, EVM Paris, optimizer
200 and OpenZeppelin 5.4.0. Run from this isolated release checkout:

```sh
FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat compile
npm run test:deploy
npm --prefix ops run typecheck
npm --prefix ops test
ARBITRUM_RPC_URL=<archive-read-rpc> npm run prepare:arbitrum-crosschain -- --out out/arbitrum-upgrade-draft
```

The final command is constructor-only preparation. With missing release inputs
it writes `DRAFT_NOT_SIGNABLE`, names the blockers and exits 2. It does not
create a signer, deploy, queue, execute, allocate or restart a service. Public
RPC keys must remain in the environment and outside committed evidence. The
output directory must be new; the writer refuses to overwrite a previous bundle.

A complete unsigned bundle additionally requires:

- Actual Arbitrum deployments for the Rebalancer implementation and both provider
  adapters, verified against the exact compiler output and immutable sources.
- A governance-attested historical per-share high-water mark (HWM), its evidence
  reference, and attestation of the preserved provider sources. HWM must be
  positive and at least the fresh ceiling PPS. The old implementation does not
  record the historical maximum; neither current PPS nor a fork fixture proves it.
- Explicit acceptance that migration waives unsettled legacy fees and resets the
  fee accrual baseline. Recheck the actual fee state immediately before execution.
- Explicit reviewed caps, a compatible service release, fresh complete NAV and
  sufficient funding for the actual transaction estimates and rollup fees.

The supported input flags are `--implementation`, `--fluid-provider`,
`--morpho-v2-provider`, `--historical-hwm`, `--attest-historical-hwm`,
`--attest-provider-sources`, `--hwm-evidence`, `--sources-evidence`,
`--accept-legacy-fee-waiver`, `--fluid-cap-bps` and `--morpho-v2-cap-bps`.
Do not fabricate an address, attestation or HWM to satisfy these inputs. Until
they are complete, the atomic upgrade is null and governance calls are absent.
A complete plan remains unsigned and requires its concrete release review.

## Staged release

1. Verify the actual service revisions and a fresh valid NAV. The currently
   inspected allocator lacks Fluid/Morpho V2 market readers and registry support;
   this preparation does not fix or attest that runtime. Do not roll this branch
   into the live services or allocate capital to either new venue until that
   support is implemented, tested and reviewed with the contract candidate.
2. Pin the canonical Arbitrum block and verify the legacy implementation/runtime,
   actual ProxyAdmin and Timelock authorities, native USDC, original provider
   order, sources, caps and Aave entry. Preserve the local ChainAgent implementation.
   Stop competing allocation/provider/governance changes during the reviewed
   transition; retain the existing two-chain configuration.
3. Verify each recorded candidate at its deployed address. Regenerate the plan
   with those addresses and the approved migration inputs.
4. Execute one actual-ProxyAdmin `upgradeAndCall` containing
   `initializeSecurityAccounting(historicalHighWaterMark)`. A bare upgrade leaves
   new security accounting uninitialized and blocks valuation/settlement. Do not
   expose an upgrade-then-initialize public gap or reuse Base's HWM.
5. Queue the full seven-provider list and both cap changes through the actual
   Arbitrum Timelock `0x5383077e9BD3D476ab52d257f552Caa6C8Ebb948`. Its observed
   delay is **24 hours**; always use the fresh on-chain delay. Queue, execute and
   cancel must retain the exact `(target, value, signature, data, eta)` tuple and
   operation ID. Preparation adds one hour of inclusion/review slack to its ETA;
   refresh the bundle if that queue window is missed.
6. After the delay, execute registration followed by both caps while new-venue
   allocations remain stopped. Caps are release ceilings, not an instruction to
   rebalance. Publish matching manifests/codehashes only after actual successful
   operations. Remove the Arbitrum `pendingProviderActivations` entries in the same
   release and preserve previous deployment/provenance records.
7. Verify the seven sources, original holdings/permissions/fees/entry/caps,
   correctly initialized HWM and complete valuation. Verify fresh cross-chain NAV,
   local allocate/deallocate and the ordinary bridge/recall path before enabling
   reviewed allocations. A local passing test is not financial readiness evidence
   for the production services.

## Fork verification and recovery

The isolated actual-state rehearsal is:

```sh
ARBITRUM_RPC_URL=<archive-read-rpc> ARBITRUM_FORK_BLOCK=<reviewed-block> npm run test:arbitrum-crosschain
```

The runner deploys the exact reviewed Hardhat Paris creation bytecodes for all
three candidates, with creation/runtime hash assertions in the test. Its local
harness uses Prague execution rules because existing live venues use newer
opcodes. This does not change the production compiler profile. The runner
forwards the read RPC and public creation data, without signing credentials.

Set `ARBITRUM_FORK_BLOCK` explicitly to the block recorded in the evidence. The runner rejects a missing RPC or pin; an unsupported archive read is a blocked
check, not a passing financial rehearsal. Record the actual command, source commit, block/hash, results and limits.
Use `FORGE_BINARY` and `SOLC_BINARY` to select an explicit local toolchain if needed.
The suite must exercise atomic migration and preservation, the real 24-hour delay,
registration/caps, and small normal deposit/withdraw round trips through both new
venues. The recorded results and execution limits are in `changes/arbitrum-crosschain-upgrade/report.md`.

Fluid's supply value is not its immediately withdrawable value: its Liquidity
layer applies withdrawal limits and available cash. Morpho V2 uses adapters and
liquidity/gates; its `maxDeposit` and `maxWithdraw` views return zero by design.
The provider must use normal `deposit`/`withdraw`, never interpret those views as
available liquidity, and never force-deallocate a position with a penalty.
USDC uses six decimals; Prime V2 shares use eighteen, while fUSDC shares use six.
Use each protocol's previews rather than treating these share amounts as USDC.

Before execution, cancel only the exact queued Timelock tuple. After security
initialization or a new venue receives funds, do not blindly restore legacy
bytecode: preserve receipt claims, unwind the actual positions and rehearse a
forward recovery against the current state. Unreadable NAV remains fail-closed;
this release does not introduce a partial-price exit or bypass stale-Tick checks.

ProviderManager and CCTP adapter replacements are separate migrations. No bridge
endpoint, extra network, role, fee rate, buffer or hub implementation is changed
by this preparation.
