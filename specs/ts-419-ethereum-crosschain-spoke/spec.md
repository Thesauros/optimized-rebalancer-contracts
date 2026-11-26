---
title: Ethereum mainnet as a spoke of the cross-chain vault
date: 2026-11-04
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

# Change: ts-419-ethereum-crosschain-spoke

Task TS-419. Add Ethereum mainnet to the cross-chain vault that runs on Base (hub)
and Arbitrum (spoke), with Compound V3 and Morpho as the Ethereum strategy
providers. The architecture does not change: Ethereum is one more spoke.

## Required behavior

1. The cross-chain registry describes Ethereum (`mainnet`): USDC, CCTP V2 with
   domain 0, a strategy over the Morpho providers already deployed on Ethereum
   plus a fresh ProviderManager and CompoundV3Provider for cUSDCv3, caps, and
   routes Base <-> Ethereum.
2. Provider implementations are reused unchanged unless the Ethereum protocol
   version differs from one already supported on Base or Arbitrum.
3. The deployment phases (1-5) and the services handle the third chain without
   code paths specific to Ethereum.
4. Adding the network to a running deployment does not discard the services'
   transfer index for the chains already covered, and never accepts state from
   another deployment.
5. The services' image carries the Ethereum manifest; the runbook gives the
   rollout order that keeps Ticks flowing.

## Acceptance

- Fork tests on Ethereum: the strategy built exactly as phase 1 builds it
  deposits, spreads within caps, refuses a cap breach and exits fully; the reused
  providers wrap the registry vaults; a real CCTP burn from Ethereum is parsed
  and finalized by a destination adapter.
- ops tests: registry addresses equal the deployment records; transfer index
  keeps covered chains across a network addition and rejects foreign state.
- Rehearsal on three forks: Base and Arbitrum handed over first, Ethereum added
  through phase 5 Timelock batches executed by the Safe, phase 4 green and phase
  5 empty on all chains, full end-to-end cycle through both spokes.

## Out of scope

Aave on Ethereum, Morpho Vault V2 (Gauntlet Prime V2), `maxChainExposure`,
any live deployment or governance transaction.
