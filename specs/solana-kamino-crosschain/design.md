---
title: Native strategy boundary and v1 accounting compatibility
date: 2026-11-07
status: active
project: optimized-rebalancer-contracts
author: cto-agent
---

# ADR: Solana is a native spoke

Existing ChainAgent, TickAccountant and NavSnapshot v1 use uint64 network IDs
and 20-byte holder addresses. Changing these in-place would alter live contract
ABI/storage and every snapshot hash. Retain this contract and project explicit
accounting aliases at the family boundary. Solana's native identity remains
`solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp`; its accounting ID is
`0x8000000000000005`, unrelated to an EVM chain ID. An alias is the last 20 bytes
of keccak256 of a versioned identity namespace and the full native public key.
Bridge configuration pins both the full public key and alias; never decode a
Solana key as an EVM address.

Use a distinct immutable EVM CCTP adapter for the native route. It implements
IBridgeAdapter so ChainAgent limits, measured movements, roles, pause and
accounting events remain unchanged. It authenticates full-width native sender
and native hook before projecting the configured alias. Native custody is an
Anchor program PDA, not an executor's wallet. Bridge burns/mints execute by CPI
with the PDA as the restricted CCTP caller. A permissionless payer supplies gas,
but cannot redirect principal.

Native strategy definitions bind protocol, program, reserve/market, mint,
collateral account and account templates. Kamino uses direct reserve liquidity
deposit and collateral redemption without an obligation, avoiding borrow and
liquidation state. Strategy execution is selected by a protocol discriminator;
new protocols add an adapter implementation and reuse shared custody/transport.

Immutable native checkpoints solve historical reproduction: Solana's standard
RPC cannot fetch historical accounts. Checkpoints carry actual balances and
on-chain reserve-derived value, with slots and times. Movement and observation
must be atomic. Historical snapshots select only finalized checkpoints within
the freshness window and include authenticated native transfer receipts in the
existing consistent-cut algorithm. Failure to reconstruct stops NAV.

Alternatives: replacing v1 ABI with bytes32 requires migration of live hub
contracts and is unnecessary for this additive integration. An EOA Solana wallet
would give executor unrestricted custody. A TS-only SDK adapter would leave the
bridge and financial authority unenforced. Current-state reads with a historical
slot parameter would silently double count or misprice historical NAV.

Risks: protocol upgrades can invalidate reserve layouts/CPI interfaces (medium,
spoke); pin discriminator/version, verify against official source and fail closed.
Native checkpoint staleness can halt settlement (medium, product); monitored
permissionless refresh. Governance misconfiguration can strand funds (low,
product); verify full endpoints before route activation. All remote identifiers
and checkpoint layouts are versioned, with no fabricated deployment defaults.

Sources inspected: Kamino klend-sdk 6a26d6f1b5afb29953ffd139ee8c0c4ca5f26ce6;
Circle solana-cctp-contracts ec16e95d28ee47f7832df4203ae07b5981d146fc;
https://developers.circle.com/cctp/references/solana-programs;
https://developers.circle.com/cctp/references/technical-guide.
