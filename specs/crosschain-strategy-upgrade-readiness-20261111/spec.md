# Production strategy implementation upgrade readiness

Change: `crosschain-strategy-upgrade-readiness-20261111`.
User requested checking readiness to update the production implementations,
then instructed "проверяй" and "продолжай". This authorizes read-only production
inspection and local compilation/fork execution, not production deployment,
proxy upgrades, governance/limit/provider changes or service restarts.

This is operational release verification, not a new product feature; new
opportunity research is not applicable. Use the existing security migration
specification and production buffer records as context. Preserve all parallel
agent branches and worktrees. Work only in codex/crosschain-prod-20261109.

Initial target: remote main 106e9059f8fd5e433a2ddd62555a1ede427020a7. Only Base
and Arbitrum Rebalancer/Strategy implementations changed since the production
cross-chain release. EpochVault, TickAccountant and ChainAgent sources did not.
Existing nonupgradeable ProviderManagers are a separate migration boundary.

During verification remote main advanced to
62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7. Freeze that refreshed target and
archive the 106e905 evidence rather than claiming it covers new bytecode.
The new target adds timelocked forceRemoveProvider and nonproxy CCTP adapter
configuration guards. Recheck the new strategy runtime, storage, unit tests,
both deployed-state forks and the companion service candidate. Verify recovery
from an empty unreadable provider through the actual Timelock delay on forks;
verify the entry provider cannot be forced out. Adapter replacement is a
separate deployment/migration boundary, not an implementation upgrade here.

Acceptance criteria:

1. Attest all actual proxy implementations/admin owners and both strategy
   runtime hashes from the chains. Reconstruct the deployed implementation
   from compiler input whose runtime exactly matches the manifest/live code.
2. Compile the target with pinned compiler/settings/dependencies. Compare the
   compiler-backed actual legacy storage struct prefix, namespace and inherited
   storage sources. Identify new fields and confirm they are zero on-chain.
3. On isolated loopback Anvil forks of both chains, locally deploy the compiled
   target and execute the actual ProxyAdmin upgradeAndCall plus initialization.
   Verify balances, supply, roles, providers/sources/caps, allowances, treasury,
   fee settings and proxy/admin identities are preserved. Verify source pins,
   non-public/repeat initialization rejection and a valid HWM.
   The initializer intentionally reapproves MAX to the same provider sources.
   USDC may have decremented a previous MAX approval; report that refresh and
   require unchanged destinations and a near-MAX prior allowance. A finite
   limited approval being expanded is not accepted as equivalent.
4. Verify post-upgrade allocation, deallocation, return-to-vault and user payout
   paths where applicable. All fork mutations must be reverted and local nodes
   stopped. Never load a production private key or broadcast to public RPCs.
5. Test healthy and provider-failure behavior of the current ops code and the
   already-existing companion fix from commit 3138060, without touching that
   other agent's checkout. Distinguish missing provider data from RPC failures.
6. Report actual HWM/legacy-fee migration requirements, exact unresolved release
   blockers and an evidence-backed go/no-go. Do not present a fork-selected
   current PPS as governance-attested historical HWM. No production release is
   claimed until all required migration values/operational dependencies exist.

Record reproducible scripts and concise evidence under the matching changes/
directory. Raw compiler outputs and temporary forks belong in ignored out/ or
the task temp directory. No credentials or environment dumps in artifacts.
