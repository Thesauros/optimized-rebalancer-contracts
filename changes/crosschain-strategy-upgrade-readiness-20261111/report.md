# Production implementation readiness — 2026-11-11

**Verdict: local strategy migration verified; production release NO-GO.**
Target main is frozen at `62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7`.
No production transaction, service restart or implementation deployment was
performed in this audit. The earlier buffer execution/allocation is a separate,
completed and explicitly authorized change.

## Immediate operational finding

The existing, unmodified Base vault already rejects an actual holder's
`instantRedeem(500000, holder, holder, 1)` with `TickNotUsable` in read-only
`eth_call`. At block 56141473, 17:37:50 UTC, accepted Tick 586 had been committed
at **14:15:41 UTC**, 12,129 seconds earlier; the existing instant age limit is
7,200 seconds. It is not frozen. The same restriction remains after the local
upgrade. A separate independent observation at 18:04:02 UTC still found Tick 586.

This is a pre-existing service availability problem, not a strategy migration
regression or the allocation buffer. Cash remains 1.102700 USDC; a stale Tick
does not prove asset loss. Restore fresh valid NAV publication and verify a live
read-only payout before releasing. Do not bypass freshness checks or raise limits.

The last NAV transaction is
`0xeb223cc0d6e5ca6c29941d9489842a5ba010b7bf16803a0c366e03d47715c60f`.
Its 254,403 execution gas at the observed price costs 0.000001526418 ETH, below
the sender's observed 0.000003448915862998 ETH. Thus an empty gas balance is
**not established as the NAV outage cause**. Server process state, pending
transactions and sanitized logs are needed. The user confirmed all services
run remotely; no SSH host/alias and username have yet been supplied.

Evidence: [live baseline](base-live-payout-baseline.json),
[independent NAV observation](live-nav-verification.json),
[current-state Base fork](base-fork-verification.json).

## Verified compatibility

| Check | Result |
| --- | --- |
| Actual production identities | All six proxy implementations and ProxyAdmin owners match the manifests. Both strategies still run the old runtime. |
| Deployed compiler baseline | Git `9a53cc7` rebuilds the exact live strategy runtime hash `0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3`. |
| New runtime | solc 0.8.33, optimizer 200, EVM Paris, OpenZeppelin 5.4.0; 22,612 bytes. Hash `0x6a9f9388ac5290c7a04b2415178eed2c197d1f11079913870b167765a229026b`. |
| Storage | All 12 existing struct fields keep their slot, offset and type; namespace and 30 inherited source files are preserved. New HWM/source fields append at slots 10/11 and are initially zero on-chain. |
| Repository EVM regression | 188 passed, zero failures/skips, including provider removal and CCTP domain guards. |
| Actual-state migrations | Base block 56141473 and Arbitrum block 523337433 pass local deployment, atomic ProxyAdmin upgradeAndCall and initialization. |
| Financial paths | 1 USDC deallocation/reallocation passes on both networks; Base return-to-vault and push-back pass; residual agent idle is zero. |
| Actual payout with fresh NAV | Latest target on real Base block 56094167 pays 0.499971 USDC to an actual holder. Remaining cash 0.602729 is below the 1.102690 allocation floor: the floor does not lock instant payouts. |
| Source identities | All five Base deployment-block sources match current sources. All five Arbitrum sources also match after two missing archive reads were resolved through the configured read RPC. No aliases in either current provider set. |
| Companion ops fix | Existing commit `3138060` passes 8 tests; healthy valuation equals the contract and provider reverts are distinguished from transport errors. |
| Combined ops candidate | Operational commit `15f1dab` + main `62d8a6f` + companion `3138060` merge without conflicts. Synthetic tree `7d7a79d568a44fcee33eef7eaad4fd74f4d97870`: 66 tests pass on the host, seven existing artifact-dependent skips, full-source ops typecheck passes. |
| Pinned runtime compatibility | In the existing Node 22.23.4 Linux image, with candidate sources mounted read-only and external networking disabled: 65 tests pass, eight skip (seven missing Hardhat artifact checks and the Anvil binary absent from the runtime image); typecheck and offline Base/Arbitrum config pass. This is not a newly packaged release image. |

Forks preserve token metadata, supply, holder balances, roles, treasury, providers,
entry, caps, fees, source identities, physical underlying balances and proxy/admin
addresses. Initialization intentionally resets the fee accrual baseline, adds
source pins/HWM and refreshes existing near-MAX USDC approvals to MAX at the
**same** destinations. No finite approval expansion is accepted by this check.
Both observed fee rates and unsettled legacy fee shares are zero.

Bare upgrades fail valuation until initialized. Random-caller, zero-HWM and
repeat initialization are rejected. Every completed fork restores its original
snapshot and stops its local node; the Timelock time-warp snapshots also restore
the original block number, timestamp and hash.

## Release inputs and dependencies still required

1. **Remote service evidence and recovery.** Identify the SSH server/user, inspect
   the actual image/source revision and logs, restore fresh NAV, and attest the
   compatible ops release before any strategy upgrade. A passing local candidate
   does not prove it is running on the server.
2. **Explicit migration values.** Each strategy needs an approved historical
   per-share high-water mark, positive and at least the fresh ceiling PPS.
   The old runtime does not store it. Fork-selected current PPS plus a test margin
   is not an attestation. Migration waives uncrystallized old fees; observed
   unsettled shares are zero, but recheck immediately before execution.
3. **Deployable implementation addresses and funding.** No target implementation
   was deployed. The known standalone implementation records on both networks
   contain a different runtime and cannot be reused for this target. At 18:02 UTC,
   Base deployment + upgrade quoted execution cost is 0.000032576496 ETH against
   0.000003448915862998 ETH available, before extra rollup/data fees. Arbitrum's
   observed balance covers its 0.0001100624464 ETH execution-only quote. Reprice
   and provide a margin before approving concrete transactions.
4. **Reviewed release and transaction bundle.** Materialize/review the tested
   combined source candidate, build and attest its image, deploy target bytecode,
   and prepare exact atomic upgradeAndCall transactions using attested HWM values.
   Public-chain execution requires separate explicit approval of that concrete
   bundle. No signable bundle is fabricated with placeholder migration values.

## Known boundaries and excluded work

The target deliberately blocks deposits/deallocations on any unreadable provider.
The old runtime permits an exit when an empty provider fails; the new runtime
rejects it with `ProviderUnavailable`. The companion fix can report a readable
lower bound for operations/monitoring; it cannot safely settle unknown NAV.
This provider-failure availability tradeoff was explicitly excluded from changes
by the user and is not silently treated as fixed or reopened here.

Latest main adds `forceRemoveProvider` through the existing Timelock. Both forks
verify the full 86,400-second delay, early rejection, exact empty failed-provider
removal, source-pin clearing, approval revocation and restored complete NAV/exit
simulation. Entry-provider removal is rejected. Removing a funded non-entry
provider would write off its valuation while receipt tokens remain for recovery;
that scenario is not an immediate liquidity guarantee or a new payout SLA.

EpochVault, EpochVaultLogic, TickAccountant and ChainAgent source files have not
changed from the reconstructed release baseline. Their implementation upgrades
are unnecessary for this target. ProviderManager and CctpV2Adapter are nonproxy
deployments: their main fixes require separate deployment/migration work and are
not installed by replacing strategy implementations.

Governance/key separation, unrelated limits, diversification and large-withdrawal
funding/SLA remain outside scope. Other agent worktrees and branches are untouched.
The initial `106e905` evidence is retained only in `baseline-106e905/`; it is not
used as proof for the refreshed bytecode.

## Reproduction and evidence

Run from this isolated product worktree. Native solc must be exactly 0.8.33 and
dependency versions must match [build evidence](build-verification.json). Set
`SOLC_BINARY` to that binary and `ORC_DEPENDENCY_ROOT` to an existing compatible
checkout containing the locked root/ops dependencies and Foundry libraries.

```bash
node changes/crosschain-strategy-upgrade-readiness-20261111/prepare-target.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-build.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/run-unit-checks.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/run-companion-checks.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-merged-ops.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-proxies.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-forks.cjs both
node changes/crosschain-strategy-upgrade-readiness-20261111/check-forks.cjs base fresh-payout
node changes/crosschain-strategy-upgrade-readiness-20261111/check-history.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-history.cjs arbitrum-configured
node changes/crosschain-strategy-upgrade-readiness-20261111/check-gas-budget.cjs
node changes/crosschain-strategy-upgrade-readiness-20261111/check-live-nav.cjs secondary
node changes/crosschain-strategy-upgrade-readiness-20261111/check-evidence.cjs
```

Configured-history mode extracts only `RPC_ARBITRUM`/`ARBITRUM_RPC_URL` from the
dependency checkout's `.env` (or `ORC_READ_RPC_ENV_FILE`), never loads signer
variables and never records its authenticated URL. All production RPC classes
have closed read allowlists. Writes, impersonation, funding and time advances
occur only in verified loopback Anvil nodes with sanitized environments.

The separate [Node 22 result](node22-ops-verification.json) was produced with
the pre-existing verified runtime image ID
`sha256:d095fde03e092f76ccedd609df53edc0d9a2ff04dd52a6f18ea38d4675ae0731`.
Its dependency lock is byte-identical to the combined candidate's lock (SHA-256
`0a413a22dc6fcde5943bf4157905dd9b1a6fd629da952a081b2ebcb0950fe010`).
Reproduce its additional runtime check after materializing the combined candidate:

```bash
docker run --rm --platform linux/amd64 --network none --read-only --tmpfs /tmp \
  --entrypoint node \
  --mount type=bind,source="$PWD/out/strategy-upgrade-readiness-20261111/merged-ops/ops",target=/app/ops,readonly \
  --mount type=bind,source="$PWD/out/strategy-upgrade-readiness-20261111/merged-ops/deploy",target=/app/deploy,readonly \
  --mount type=bind,source="$PWD/out/strategy-upgrade-readiness-20261111/merged-ops/deployments",target=/app/deployments,readonly \
  --mount type=bind,source="$PWD/changes/crosschain-strategy-upgrade-readiness-20261111/check-node22.cjs",target=/checks/check-node22.cjs,readonly \
  thesauros/crosschain-ops:e56b42e-clean /checks/check-node22.cjs
```

The offline consistency check is intentionally tied to these dated observations,
including the stale production baseline. If live NAV recovers or deployment
identities change, capture a new dated verification instead of interpreting the
old evidence as a current release approval.
