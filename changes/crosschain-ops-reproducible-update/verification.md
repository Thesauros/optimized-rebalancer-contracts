# Reproducible ops update verification

Change: `crosschain-ops-reproducible-update`.
Implementation: e56b42e on codex/crosschain-prod-20261109, based on main 106e905.

| Acceptance criterion | Evidence | Result |
|---|---|---|
| Clean-source image build | Detached clean checkout of e56b42e; Docker directory context, --pull --no-cache, linux/amd64; npm ci from the committed lockfile; no local dependencies or Ethereum manifest | Verified |
| Runtime selection | 8 configuration tests cover discovery, explicit selection, unknown/duplicate/empty networks, missing manifests/RPC, identity mismatches, missing hub, staged Ethereum and accountant coverage | Verified |
| Monitoring/integrity | 3 deployment-check tests verify two-chain monitoring, detection of an omitted active chain, and unchanged full-registry deployment verification | Verified |
| Image contents/runtime | ARM64 and AMD64 offline smoke: Node 22.23.4, non-root, SQLite, only cross-chain manifests, no env files/skills/git/host scripts | Verified |
| Update/rollback | Compose configuration validates; all stand services resolve CROSSCHAIN_OPS_IMAGE; documented same-image preflight/rollout, existing volume preservation and rollback | Verified locally |

Service, test and rehearsal TypeScript sources typecheck against the packaged
Node 22 type definitions. Final ops suite with the subsequent unsigned buffer
preparation tests: 65 cases, 57 passed, 8 existing skips (7 compiled-artifact ABI
checks and 1 Anvil-dependent test). No Solidity changed or compiled for this
packaging fix. Existing full-registry network/route/limit configuration unchanged.

A wall-clock pacing test failed once under concurrent x86 emulation and passed
in isolation. The npm test command now serializes test files to remove that CPU
contention; pacing implementation and production RPC budgets are unchanged.

Build from a checked-out directory, as documented and done in CI. A stdin tar
build does not apply the .dockerignore filter; that alternative was rejected by
the image-content smoke check and is not the supported release procedure.

The source patch does not change Solidity, deployment manifests, registry limits,
NAV valuation, keeper funding, roles or provider allocations. CI was added and
its commands executed locally; no remote CI run, product push, production
restart, contract upgrade or mainnet transaction is claimed.

The dependency install still reports the existing lockfile advisories (one high,
one moderate). Production dependencies were deliberately not upgraded in this
scope; this is not a full dependency/security release clearance.

Follow-up buffer investigation is separately specified and verified under
`specs/base-buffer-remove-fixed-floor/` and `changes/base-buffer-remove-fixed-floor/`.
Its unsigned proposal is not an applied limit change.
