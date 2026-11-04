---
title: Optimized vault financial security remediation
date: 2026-10-27
status: approved-for-local-implementation
project: optimized-rebalancer-contracts
author: product-cto-security
---

# Change: security-remediation-2026-10-27

Fix the user-selected SC-001/003/004/005/007/008/010 only. The written workspace
scope is canonical. No push, deployment, real environment/keys, chain reads or
live transactions. Research subcycle is not applicable: requirements come from
the completed source audit and explicit user selection, not a new product idea.

## Required behavior

1. Unknown provider NAV fails closed in conversions, fee settlement and exits.
   Complete NAV includes idle underlying, which is used before provider actions.
   When NAV is known, failed/short withdrawal actions are isolated and actual
   receipts determine remaining liquidity; insufficient liquidity reverts atomically.
2. Performance fees accrue only above a per-share high-water mark after management
   fees. Deposits/withdrawals preserve the mark; loss recovery to a former peak
   is not charged again. Fee assets always remain strictly below positive NAV.
3. Storage fields are appended to the existing ERC7201 struct. Fresh vaults start
   at HWM1e18. Existing proxies require atomic upgrade plus authorized security
   reinitialization with an explicit HWM at least current PPS; no historic peak is
   invented. Only the timelock or the actual ERC1967 ProxyAdmin may bootstrap:
   upgradeAndCall runs with ProxyAdmin as sender. Migration waives uncrystallized
   legacy fees and restarts the clock.
4. Providers and economic source addresses must be unique contracts. Removal
   requires a readable zero position and no nonzero ERC20-like receipt claim,
   including dust and future recovery claims at zero NAV. Source identity is
   pinned and used for approval cleanup. An immediate registry mutation cannot
   silently change the price/asset boundary. New registry entries are write-once;
   migrations deploy a new registry/adapter and use the vault timelock.
5. Every ordinary deployment network uses atomic VaultFactory initialization.

## Acceptance

Run offline Solidity/EVM tests for funded view failure/recovery, alternative
liquidity, short receipts, zero/long-idle fee bounds, HWM loss/recovery/flows,
duplicate/alias sources, funded/dust/unreadable removal, registry immutability,
pinned identity, upgrade bootstrap and layout preservation, and atomic factory.
Keep existing compatible unit/deploy/tick tests passing. Existing tests requiring
unsafe partial-NAV exits or removal of unreadable providers must be updated to
the new requirement. Record exact results, source baseline, branch and commit.

Human validation: user approved scope; CTO implements; independent QA/Security
inspect changes and executed evidence before local delivery. On-chain migration,
historical HWM attestation and release are separate future approvals.
