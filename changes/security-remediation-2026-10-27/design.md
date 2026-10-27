---
title: Optimized vault accounting and source identity design
date: 2026-10-27
status: implementation
project: optimized-rebalancer-contracts
author: cto-agent
---

Append HWM and provider-source pins after the baseline struct fields. New
deployments initialize them; old proxies fail closed until reinitializer2 pins
the current approved sources and records a governance-attested historic HWM.
Only the timelock or actual ERC1967 ProxyAdmin can call it; ProxyAdmin is the
delegatecall sender during upgradeAndCall, permitting one authorized transaction.
The migration must attest sources against previous deployment records: software
cannot reconstruct a source already changed in an old mutable registry or past
unrecorded price peaks. No live migration is authorized by this change.

Performance gain is positive post-management asset/share price above HWM. Fee
shares use the common post-fee denominator; HWM advances to actual post-mint PPS
only on a new peak. HWM rounds upward and its asset equivalent rounds upward, so
rounding cannot re-charge a recovered peak. Total fee assets cap at NAV minus one base unit, preserving a
positive denominator even beyond20years. Integer fee-share rounding is explicit.

Unknown NAV blocks ordinary user settlement, prioritizing principal claims over
availability. Healthy economic NAV plus an illiquid provider still permits using
other sources. No emergency partial redemption is introduced. Source pins turn
registry drift into a visible failure rather than silent valuation substitution.
Write-once registries require explicit new-adapter migrations instead of hot edits.

Provider removal needs a known zero position, not a caught-error zero. Check the
entire new list and all removals before approvals or state changes, then revoke
saved old source approvals and grant new ones. Aliases cannot revoke retained
source allowance because they are rejected. Reordering remains supported.

Risk: old uninitialized proxies become unavailable until governance migration;
historical HWM correctness is a governance attestation. Mitigate with atomic
upgradeAndCall and explicit signed migration evidence. All existing storage
offsets and ERC7201 slot constants must remain unchanged.
