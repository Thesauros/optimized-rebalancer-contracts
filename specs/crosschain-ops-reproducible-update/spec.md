# Reproducible cross-chain service updates

Change: `crosschain-ops-reproducible-update`.

## Scope and evidence

The user authorized only reproducible service builds and startup for the existing
Base/Arbitrum deployment. The baseline Dockerfile copies absent `ops/scripts`
and `deployments/mainnet/crosschain.json`; `loadChains()` also requires every
supported registry network, including undeployed Ethereum. This prevents a clean
checkout from reproducing the service release.

Product opportunity research is not applicable: this repairs a demonstrated
release regression with a deterministic outcome, without a new product feature,
economic policy, or user workflow. Existing server/deployment runbooks are reused.

## Acceptance criteria

1. A clean source tree builds the ops image using locked dependencies and a pinned
   Node 22 base image, without local dependencies, secrets or an Ethereum manifest.
2. Runtime networks default to the cross-chain manifests actually present in the
   selected manifest directory. Explicit `CROSSCHAIN_NETWORKS` selection rejects
   unknown/duplicate/empty entries and requires every selected manifest and RPC.
   Exactly one hub is required; manifest network/chain/role identities must match
   the registry. Malformed present manifests are errors, never silently skipped.
3. Monitor deployment checks use the runtime network set. Deployment scripts keep
   their existing full-registry behavior. No active accountant network may be
   silently omitted: preflight rejects missing coverage, and the existing NAV
   chain-membership rejection is preserved. Staged additional networks remain
   supported when their manifests are present.
4. Docker includes service sources, registry and available cross-chain manifests;
   it excludes private env files, skill directories, unrelated deployment artifacts
   and local caches. Runtime remains non-root and state keeps the existing volume.
5. A read-only configuration smoke check runs inside the built image with only
   Base/Arbitrum configured; negative configuration cases fail before RPC access.
   Existing ops regression tests pass. The update/rollback runbook uses the same
   image for preflight and service rollout, preserves state, and identifies the
   release by commit/image digest.

## Excluded work and release boundary

No Solidity changes, strategy upgrades, governance/key rotation, provider-failure
valuation changes, limit changes, withdrawal/funding changes, diversification,
production restarts, signed transactions, or product-branch publication.

Local implementation and verification are authorized. A live rollout is a
separate action. QA checks each criterion; Security checks manifest selection,
omitted-chain rejection and image contents; Orchestrator records results in the
change verification artifact. No separate human gate is added to local work.
