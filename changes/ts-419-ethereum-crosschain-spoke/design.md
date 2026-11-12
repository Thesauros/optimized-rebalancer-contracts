---
title: Ethereum spoke design
date: 2026-11-04
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

The registry already models N chains; phases 1-5, the NAV engine and the
monitor iterate it. Ethereum is a registry entry, not new code.

## Protocol versions (checked on-chain 2026-11-04)

| Component | Ethereum | Supported on Base/Arbitrum | Decision |
|---|---|---|---|
| CCTP TokenMessengerV2 | same proxy and implementation as Base | yes | reuse adapter |
| CCTP MessageTransmitterV2 | `version()` 1, `localDomain()` 0; implementation code differs | yes | reuse adapter; real-burn fork test from Ethereum |
| Comet cUSDCv3 `0xc3d6…cdc3` | `version()` "0", base token USDC | same on Base/Arbitrum | reuse CompoundV3Provider; fresh ProviderManager as on Base/Arbitrum |
| Morpho vaults (Steakhouse, Gauntlet Prime, Smokehouse) | MetaMorpho V1.0 | V1.0 (GauntletCore Base) and V1.1 | reuse the deployed Ethereum MorphoProviders |
| MorphoProvider code | runtime code equal to Base/Arbitrum (metadata stripped) | — | no change |

No contract changes. Entry provider: Steakhouse, the largest of the three vaults
(66M USDC against 21M and 11M), uncapped like the entry provider on the other
chains. Caps mirror Base: Compound 50%, Prime 40%, the higher-risk vault 30%.
Routes: hub <-> spoke only, as for Arbitrum. Confirmations: 12 blocks.

## Rollout hazards found and handled

- **Transfer index fingerprint.** It covered all registry chains, so adding one
  would discard the saved index on the first restart: a full re-scan of Base and
  Arbitrum (1.6M and 11.5M blocks since the stand deployment, as of 2026-11-04)
  through a 100-block log cap, i.e. the cold start that stops Ticks. The index now also
  accepts a file whose fingerprint is exactly that of the chains it covers (same
  keys, chain ids and agent addresses); state from any other deployment is
  still rejected.
- **Rewind below deployment.** Found by the rehearsal, present on main: the
  index rewinds a saved mark by 5000 blocks against reorgs, and a mark taken
  soon after deployment then scans below the manifest's start block, where the
  agent has no events. Harmless on a live chain; on a fork those blocks go to
  the upstream RPC, and the public endpoint answered 429, failing NAV. The scan
  now starts no lower than the start block, as `EventCache` already does.
- **Image.** `ops/Dockerfile` and `.dockerignore` listed each manifest by hand, so
  the image could not be built before phase 1 produced the Ethereum one - and
  `COPY ops/scripts` named a directory commit `0c420d3` had deleted, so it could not
  be built at all. Both are fixed: the Dockerfile copies `deployments` once, the
  allowlist admits `deployments/*/crosschain.json` by glob, and `ops/scripts` is
  restored. A registered-but-undeployed network no longer breaks a build; it breaks
  service startup instead, which is where `missing manifest` belongs.
- **Order.** The services must know Ethereum before `setChains` executes, or the
  NAV service rejects the accountant's chain set; until then they ignore it. The
  runbook (§6a) fixes the order: queue, roll the services, execute. §6a now also
  carries the transfer-index backup, the rollback steps and the point of no return
  (the Timelock executing `setChains`), because the order alone did not say what to
  do when the rollout has to be undone.

## Review fixes (2026-11-11)

Behaviour changes made while implementing the open findings of `419-rewiev_codex.md`
and `419-rewiev_qwen.md`. `verification.md` holds the per-item list and the results.

- **NAV prices an unhealthy strategy instead of throwing.** `positionsAt` read
  `providersHealthy` after `convertToAssets`, but `convertToAssets` reverts
  `ProviderUnavailable` while any provider view fails, so one bad provider view on
  one chain stopped Ticks for the whole vault and the documented offer-carry rule
  could never run. Health is now read first and the unhealthy path prices the
  position from readable balances: the strategy's own USDC balance plus every
  provider's `getDepositBalance` at the same block tag, times the agent's share of
  `totalSupply`. It refuses rather than approximates in two cases - an unreadable
  provider balance, and a non-zero management or performance fee, whose share
  accrual it cannot reproduce. Cross-chain strategies are initialized with both
  fees at 0, so the normal degraded case prices; the fee case is a loud stop if
  governance ever changes it. The independent verifier shares `positionsAt`, so it
  stays consistent by construction.
- **Phase 5 refuses to drop a chain.** `05-governance-plan.ts` builds the hub's
  `setChains` from `NETWORKS`, which `REHEARSAL_NETWORKS` narrows. A stray exported
  variable therefore queued a batch that removed Ethereum from the accountant, and
  `_setChains` has no on-chain guard against removing a funded chain. The plan now
  compares the chain set it is about to propose against the chains the accountant
  actually tracks, names any chain it would drop, and stops unless
  `CROSSCHAIN_ALLOW_DROP_CHAINS=1`. The guard is off-chain only, by choice: adding
  one to `TickAccountant` is a contract change to a live proxy.
- **The gas alert is per chain.** One `MONITOR_MIN_GAS_WEI` for every chain cannot
  be right: 0.0002 ETH is a sensible L2 floor and is about twenty times below one
  Ethereum strategy operation. `MONITOR_MIN_GAS_WEI_<KEY>` overrides the shared
  value, which keeps existing environments working unchanged.
- **Preflight blocks a public send path.** Broadcasting through a free shared
  endpoint fails in two ways an operator cannot see - the send is dropped under
  free-plan limits, and on Ethereum the signed transaction is published to the
  public mempool before inclusion. It is now a preflight failure rather than a
  warning. The chains' own endpoints (`mainnet.base.org`, `arb1.arbitrum.io/rpc`)
  are deliberately not in the list: they are the reliable path into a sequencer and
  there is no public mempool to read there. Matching is by host suffix, so a paid
  tier on a listed host is caught too; `OPS_ALLOW_PUBLIC_SEND_ENDPOINT=1` says that
  is deliberate and downgrades it to a warning.
- **`RPC_TIMEOUT_MS=""` means unset.** It produced a zero timeout through
  `Number('')`; `envNumber` already handled the empty-string case.

## Tooling

`REHEARSAL_NETWORKS` narrows the registry so the rehearsal can hand over Base
and Arbitrum first and then add Ethereum through the real phase 5 batches.
The rehearsal was also adapted to Foundry 1.8: the wallet JSON envelope and
`FOUNDRY_AUTO_DETECT_REMAPPINGS=false` for hardhat-foundry.

## Risks

- Ethereum gas: strategy operations cost 2.4-3.9M gas, driven by MetaMorpho
  views (Smokehouse has 21 markets). Probability of a problem: low; blast radius:
  operating cost. Mitigation: budget hot wallets; dropping Smokehouse removes
  the heaviest view.
- Monitor shows governance critical between rollout and execution. Probability:
  certain; blast radius: alert noise for the Timelock delay. Accepted and
  documented.
