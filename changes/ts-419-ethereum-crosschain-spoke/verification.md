---
title: Ethereum spoke verification
date: 2026-11-05
status: local-validation
project: optimized-rebalancer-contracts
author: cto-agent
---

Branch `feat/ts-419-crosschain-ethereum` from main. No live network, deployment,
governance transaction or push. Foundry 1.8.7, solc 0.8.33, Node 22.21.

## Results

| Check | Result |
|---|---|
| Foundry, non-fork suites | 176/176 |
| Fork, Ethereum strategy (`CrossChainStrategyEthereum.t.sol`) | 4/4: reused providers wrap the registry vaults, wiring equals the registry, deposit spreads within caps and exits fully, a cap breach reverts |
| Fork, CCTP (`CctpV2Adapter.t.sol`) | 3/3, including a real burn from Ethereum (domain 0) finalized by a Base adapter |
| ops tests | 48/49; the failure (`src/errors.json matches the compiled artifacts`) fails on main too |
| Rehearsal, stage 1 (Base + Arbitrum from scratch, `REHEARSAL_NETWORKS=base,arbitrum`) | phases 1-4 green, phase 5 empty |
| Rehearsal, stage 2 (add Ethereum) | phases 1-3 on Ethereum; phase 5 Timelock batches queued and executed by the impersonated Safe on Base and Arbitrum; phase 4 green on all three; phase 5 empty on all three |
| Rehearsal, end-to-end | see below |

`tsc` reports only the `node:sqlite` error that main has.

## End-to-end runs

Run 10 passed steps 1-7: deposit, ticks, epoch close, clearing and keeper claim;
CCTP burns from Base to Arbitrum and to Ethereum; a tick with both transfers in
flight; relayer delivery of exactly 50 000 USDC on each spoke; allocation into the
Ethereum strategy; tick 4 re-derived identically by the independent verifier;
monitor with no critical check (55 checks). Step 8 stopped on a fork transport
error: mining a block made anvil read the EIP-2935 history contract from the
upstream (`eth.drpc.org`), which closed the connection. The driver now retries
`evm_mine` on fork upstream errors only (a failed read mines no block).

Run 11 repeated steps 1-7 with the same results and reached step 8; 16 s later
the machine went to clamshell sleep, and on the next maintenance wake the forks
could not resolve their upstream hosts (DNS), so the run failed there. Steps 8
(queued and instant redemption), 8b (return path from both spokes) and 9
(indexer and API) have not completed with Ethereum in the set yet.

Run 12 (sleep prevented) failed earlier, in phase 1 on Ethereum: the fork's
upstream answered 408 "Request timeout on the free plan, please upgrade to
paid plan". Each run on free endpoints fails at a different point; the
remaining steps need a paid archive Ethereum RPC (`ETHEREUM_FORK_URL`).

Earlier runs failed on public RPC limits before reaching the cycle; each cause
was fixed (fork retries and compute budget, archive endpoint for Ethereum, a
configurable read timeout) except the one in the code below.

## Defect found by the rehearsal

The transfer index rewinds a saved scan mark 5000 blocks against reorgs. A mark
taken soon after deployment then scanned below the manifest's start block, where
the agent has no events. On a fork those blocks are served by the upstream RPC;
the public Base endpoint answered 429 and NAV failed (runs 8 and 9). The scan now
starts no lower than the start block, as `EventCache` already does. Present on
main; harmless on a live chain apart from wasted log queries.

## Measured on the Ethereum fork

Deployer, phases 1-3: 31 transactions, 16.7 M gas (0.017 ETH at 1 gwei, 0.08 ETH
at 5 gwei). Strategy deposit 2.4 M, withdraw 2.8 M, rebalance 3.9 M gas; the
Smokehouse view 1.2 M, under the 3 M provider view stipend.

## Not verified here

Live deployment and the production rollout order (queue, roll services, execute)
are documented in docs/crosschain-deployment.md §6a and remain operator steps.
