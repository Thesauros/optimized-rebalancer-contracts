---
title: Solana strategies and Kamino USDC spoke
date: 2026-11-07
status: active
project: optimized-rebalancer-contracts
author: product-agent
---

# Change: solana-kamino-crosschain

## Outcome and scope

The Base EpochVault remains the sole user deposit, share, redemption and fee
boundary. Its ChainAgent can move native USDC through CCTP V2 to a Solana
program-controlled spoke, allocate it to Kamino Lending, redeem collateral,
and bridge USDC back. No user vault, shares or borrowing is created on Solana.
Implementation is delivered as a local commit from origin/main; do not push.
Deployment, governance execution and transactions with real funds are outside
this change's authorization.

## Opportunity research / PR-FAQ

Existing EVM spokes establish the capital movement and NAV model. Solana adds
access to lending markets while retaining the existing Base user experience.
The treasury operator needs observable positions, current rates, bounded sends,
permissionless delivery and safe unwind. Future Solana protocols must reuse
custody, authorization, transport and accounting rather than copy Kamino code.

The desired announcement is: "The USDC vault can allocate capital to Kamino
on Solana and bring it back to Base, with reproducible NAV and explicit network
and protocol attribution."

| Question | Answer |
|---|---|
| Who benefits? | Existing Base USDC depositors and treasury operators. |
| What changes for depositors? | The strategy universe expands; requests and claims remain on Base. |
| What is Kamino here? | Unlevered reserve lending: USDC becomes redeemable cTokens held by the agent PDA. |
| What is excluded? | Borrowing, leverage, swaps, retail Solana deposits, mainnet deployment. |
| What proves success? | Deposit/redeem instruction conformance, both bridge directions, NAV conservation, adversarial tests. |

Hypothesis: one complete Base → Solana → Kamino → Solana → Base cycle
preserves principal within explicit bridge/slippage limits and reflects actual
interest. Leading indicators are finalized receipts, dynamic cToken value and
reserve-derived APR/APY. Validate before activation and over the first 24 hours
of a separately authorized capped rehearsal. Reconsider on unexplained NAV
drift, stale checkpoints, incomplete authentication or inability to unwind.

Improve the existing architecture with a native family boundary. Agent execution
fit: AI-native SDD implementation, deterministic financial execution. Outcome
ambiguity is low; cross-family variation is high; official SDK/source and local
toolchains are available; production actions are irreversible and separately
reviewed; shared adapters lower the cost of future integrations. Reuse the
TS-419 spec, existing bridge/consistent-cut tests, and Product research and CTO
ADR templates.

## Requirements / acceptance criteria

| ID | Requirement | Verification |
|---|---|---|
| R1 | New branch is based on fetched main; final result is committed locally, never pushed. | Git ancestry/status. |
| R2 | Explicit family, native network identity, USDC mint, CCTP domain and protocol; Solana never enters ethers/Hardhat loaders. | Registry/type/runtime tests. |
| R3 | Agent PDA owns idle USDC and Kamino cTokens. Executor can deposit and redeem with measured deltas and minimum output. No arbitrary recipient or arbitrary CPI. | Rust integration/adversarial tests. |
| R4 | Governance fixes protocol/program/accounts, executor and guardian; pause blocks allocation/sends, preserves exits/receives; changing strategy requires empty collateral. | Rust tests. |
| R5 | Full 32-byte native identifiers survive Base ↔ Solana transport. CCTP authenticates origin, mint, recipient, caller, finality and hook. Only agent can finalize, preventing unrecorded mints. | Solidity/Rust/TS message vectors. |
| R6 | Sends enforce transfer, fee and refillable volume limits; durable transfer IDs/receipts prevent replay, support restart and write-down. | Boundary/replay tests. |
| R7 | Current position uses actual cToken balance and reserve exchange rate; APR/APY derives from reserve state via official SDK; unavailable data fails closed. | Recorded reserve vectors and reader tests. |
| R8 | Native finalized observations and transfer receipts integrate with existing NAV and consistent cut; no double counting, no zero fallback, reproducible historical values. | Mixed-family snapshot tests. |
| R9 | Operational commands simulate before opt-in broadcast, use separate Solana key/RPC, durable receipts, manifest-bound program/PDA checks and readiness checks. | CLI/build tests. |
| R10 | Adding a Solana strategy reuses runtime, registry, custody, bridge, receipts and accounting; Kamino-specific code lives behind a strategy adapter boundary. | Code and extension documentation. |
| R11 | Existing EVM contracts/flows and canonical v1 snapshot encoding remain compatible. | Existing ops and Solidity regression suites. |

## Architecture constraints and failure handling

Amounts are integer USDC micro-units. No decimal Number conversion for principal.
Use standard CCTP finality (2000). Native addresses are always PublicKey/bytes32.
The v1 hub's uint64/address fields use explicitly registered accounting identities;
these are aliases, never truncated native addresses or EVM RPC chain IDs.
Use an internal high-bit-set uint64 namespace for the Solana accounting domain.
The bridge must validate the full remote public key before returning its alias.

Solana RPC does not support historical getAccountInfo. Historical NAV therefore
uses immutable, program-authenticated checkpoints with finalized slot/time and
measured custody/strategy value, not present-day accounts queried with a fake
blockTag. A stale or missing observation halts a new Tick. Each custody movement
must atomically create a checkpoint; no indexer status setter constitutes receipt.
The existing hub authorized NAV updater remains the valuation trust boundary.

Failed destination delivery is retried without a new burn. A timed-out send is
reconciled by signature/receipt before re-signing. Bridge fees and lending
liquidity are explicit. Redeeming all uses collateral units; partial exact-USDC
withdrawals round collateral up and enforce the minimum received. No fabricated
rate, reserve, deployment address, or successful live rehearsal is acceptable.

## Rollout / observability / validation

Prepare manifest and unsigned governance plan; verify native cluster genesis,
program IDs, PDA seeds, reserve owner/mint/market and token authority. Deploy and
activate only in a separately authorized session. Register the alias, routes and
chain with the Base Timelock, then enable operators. Start with capped capital,
observe both directions and unwind before increasing limits. Rollback disables
new allocation/sends while retaining redeem and receive paths.

Expose network, family, protocol, reserve, slot, cToken units, USDC value,
APR/APY, liquid withdrawal capacity, checkpoint age, pending transfers and last
error. Alert on stale observations, exhausted volume, stuck attestations and
position/receipt mismatch.

| Step | Human reviewer | Criteria | Evidence |
|---|---|---|---|
| Scope / SDD | Founder through this request | Base-only vault, USDC, native Solana, scalable strategy model | This spec and ADR. |
| Implementation | CTO role | Requirements and architecture contracts | Code, builds, tests. |
| QA / Security | Separate review stages | Written requirements; adversarial controls | Verification report. |
| Merge / deployment | Repository owner | Local diff, limitations, unsigned plan | Local commit and runbook. |
| Production learning | Treasury owner | Principal conservation and successful unwind | Authorized rehearsal and monitoring. |

## Delivery gates

Product requirements → CTO implementation → QA → Security → delivery. Record
test commands/results and unresolved limitations in verification.md. Critical or
high defects block readiness. Test-environment availability and mainnet rehearsal
are reported separately from code verification. Do not label unexecuted checks PASS.
