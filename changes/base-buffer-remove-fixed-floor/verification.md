# Fixed buffer review verification

Change: `base-buffer-remove-fixed-floor`.

Live Base/Arbitrum check through the rebuilt ops image: accepted tick 542, NAV
11.025383 USDC, hub cash 5 USDC, strategies 4.019054 + 2.006335 USDC; no pending
deposits, liabilities or reserved withdrawals. Providers healthy, no pauses or
quarantine. The allocation floor is max(5 USDC, 10% of the last accepted bid NAV).
Funded claims and instant redemptions do not enforce that allocation floor.

## Actual deployed-contract fork

Read-only mainnet input; transactions ran only on a loopback Anvil fork, verified
by client identity and chain id. The original local snapshot was restored.
Machine-readable evidence: `fork-verification.json`.

- Existing fixed 5 USDC floor rejects even one additional allocation unit.
- Changing only minimumBuffer to zero preserves the other seven tuple values.
- The remaining 10% reserve was 1.102538 USDC; an excess allocation still reverted.
- 3.897462 USDC reached the existing ChainAgent and Aave-backed strategy.
- A 0.499902 USDC instant user payout succeeded despite taking cash below the
  allocation floor: that floor does not trap user withdrawal liquidity.
- 0.5 USDC was deallocated and returned from the strategy to replenish the vault.

## Unsigned governance proposal

The historical October 29 10% plan was never queued and missed its queue window.
The older 5% queued operation is expired. Neither should be executed for this
review. Reused the historical read-only 10% preparation utility, with an added
check that the active proxy implementation matches the manifest.

Fresh plan: `ops/governance/base-buffer-10pct-20261109.json`. It changes only
minimumBuffer 5 USDC -> 0, keeps minBufferRatio 10%, and preserves every other
limit exactly. Target setLimits eth_call and Timelock queue eth_call passed.
Operation: 0xf70f7c259ff3d458977f4e45a8abc1c67097f146bcf179d314eef044ae6d6841.
Queue inclusion deadline: 2026-11-10 00:15 UTC.
Execution ETA: 2026-11-11 00:15 UTC; actual Timelock delay is 86400 seconds.
Recheck the plan and current limits before any external signature. If the queue
window is missed, prepare a fresh sibling proposal; never overwrite this one.

No keys loaded or mainnet transactions sent. The plan is not queued/applied;
cash remains 5 USDC in production. A parameter change alone does not allocate
cash: a healthy allocator or a separately authorized push/allocate is still
needed after execution. This scoped verification does not resolve the excluded
NAV-failure, security-upgrade, governance, funding-SLA or concentration risks.
