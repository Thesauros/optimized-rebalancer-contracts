# Arbitrum cross-chain Strategy upgrade

This release prepares the existing Arbitrum Strategy
`0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71` for the same reviewed Rebalancer
runtime already installed on Base (`0x6a9f9388ac5290c7a04b2415178eed2c197d1f11079913870b167765a229026b`).
It preserves the five existing providers, their order, Aave entry, positions,
shareholders, roles, original caps, treasury and fee rates. It appends separately
deployed Fluid and Gauntlet USDC Prime Morpho V2 adapters for native Arbitrum USDC.
The proposed new caps match Base: 3000 and 2000 bps respectively. No hub,
ChainAgent, ProviderManager or bridge implementation is replaced.

The new scoped unsigned CLI validates actual on-chain identity, legacy runtime,
reviewed provider sources/caps, new source assets/gates, exact compiler artifacts
and immutable-linked candidate runtime. It requires actual deployed candidate
addresses and supported migration evidence before emitting atomic
`upgradeAndCall(initializeSecurityAccounting(historicalHwm))` or exact Timelock
queue/execute/cancel tuples. It never signs, broadcasts or edits live manifests.

## Verification

| Check | Result |
| --- | --- |
| Hardhat compile | 88 files; Solidity 0.8.33, Paris, optimizer 200, OZ 5.4.0 |
| Solidity regression/invariants | 204 passed; zero failures/skips; Paris |
| Deployment/preparation tests | 46 passed; zero failures/skips |
| Ops tests | 104 passed; zero failures/skips |
| Preparation/test and ops TypeScript checks | passed |
| Exact legacy runtime and storage compatibility | 12 legacy fields preserved; new state appended at slots 10/11 |
| Actual Arbitrum fork, block 526524948 | 6 passed; zero failures/skips |
| Live read-only constructor preparation | target runtime and both source-linked constructors verified; DRAFT_NOT_SIGNABLE |

The fork deploys the exact reviewed Paris creation bytecodes from Hardhat, with
creation/runtime hash assertions for all three candidates. The local harness
executes under Prague so existing venue contracts can use their current opcodes;
this is separate from the candidates' production compiler settings. The non-fork regression run explicitly sets `FOUNDRY_EVM_VERSION=paris`;
the existing global fork execution default is preserved.
The reproducible runner is `npm run test:arbitrum-crosschain` with explicit read
RPC and L2 block pin. It forwards no signing credentials.

Fork scenarios cover legacy state and role preservation, atomic initialization
and negative initialization, real delayed registration/caps, normal Fluid and V2
deposit/withdraw round trips, atomic rejection of oversized allocation and the
existing spoke ChainAgent allocate/deallocate cycle. The Base hub, bridge and
full production NAV/allocator runtime are not simulated as a complete live cycle.

## Live observations and release state

Snapshot block 526525483 contains 3.015051 USDC in the original Aave position,
2.999892 Strategy shares, zero management/performance fees and zero accrued fee
shares. Complete Strategy/token event history and verified Aave source behavior
support a historical settled-state ceiling PPS reconstruction of
1005053181914548924 through that snapshot. Historical source identity was
independently checked by rebuilding the exact deployed ProviderManager and Aave
registry runtimes and proving mandatory mutation events. Complete address logs
exclude unreviewed retargets/aliases; the known Pool upgrade is already included
in the interval analysis. Explorer account-call lists were incomplete and were
not used for this proof. This remains dated evidence, not a permanent signing value. Refresh the final interval and all new logs immediately before
attesting and signing. The detailed audit retains governance-attestation and
fee-acceptance flags as false; the evidence itself does not sign or authorize a
transaction.

## Candidate deployments on 25 November 2026

After the deployer received ETH, it deployed the three candidates on Arbitrum
One from commit `499ec1b637c527ec8a19f50b1617890d2a1e247f`.

| Contract | Address | Creation receipt |
| --- | --- | --- |
| Rebalancer | `0x859b6FBbE685d6823a56125BD58A224b1925c7D4` | [Block 527452049](https://arbiscan.io/tx/0xc9ae78ecaa256a84cc56843dcad5df81d083a45fb3eb4980bd4f9e603768ee9f) |
| FluidProvider | `0xa4885485bEDfFc131f6b67DC87B13a3e89C58852` | [Block 527452061](https://arbiscan.io/tx/0x6e576ab23a44df9c39856f4bc26ae147bb1659996f60e009bc4ce5dccc9806e8) |
| MorphoV2Provider (Gauntlet USDC Prime) | `0xce43d620849c2673FfB2D7c526B3cBE67bd77248` | [Block 527452073](https://arbiscan.io/tx/0x8aec97a895d9cb20a34dd7610a39ef85e1e3b7a6f7cf0c64da6e543315f06767) |

The three transactions cost 0.00015227377277 ETH in total. The deployed code
matched the reviewed runtime for each constructor. Both adapters returned their
configured source, and both sources reported native Arbitrum USDC. At block
527452292 the Strategy still used its original implementation and five providers.
The release record includes the transaction hashes, bytecode hashes, fees
and post-deployment snapshot. [Deployment evidence](candidate-deployments.json)

The existing allocator still lacks Fluid/Morpho V2 market readers and registry
support. Registering adapters alone does not enable allocation into these markets.
A compatible allocator release is required before enabling that allocation.

Evidence: `build-verification.json`, `fork-verification.json`, `verification.json`,
`preparation.json`, `release-inputs-audit.json`, `source-scope-closure.json`
and `research.md`. Instructions:
`docs/arbitrum-crosschain-upgrade.md`.
