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
- **Image.** `ops/Dockerfile` and `.dockerignore` list each manifest by hand; the
  Ethereum manifest is added, so the image cannot be built before phase 1.
- **Order.** The services must know Ethereum before `setChains` executes, or the
  NAV service rejects the accountant's chain set; until then they ignore it. The
  runbook (§6a) fixes the order: queue, roll the services, execute.

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
