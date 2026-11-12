# Base vault fixed buffer review

Change: `base-buffer-remove-fixed-floor`.

The user reopened the buffer question after excluding other limit changes. Live
NAV is about 11.03 USDC, of which the fixed 5 USDC floor keeps approximately 45%
in the hub vault. This is allocation headroom, not a prohibition on paying users.

Prepare and verify a reviewable unsigned proposal that changes only
`minimumBuffer` from 5 USDC to zero, preserving the existing 10% `minBufferRatio`
and all seven other tuple values. No Solidity, security migration, role/key,
other stand-limit, funding/SLA or diversification changes are authorized.

Reuse the historical read-only 10% preparation tool, not the separate 5% signing
tool. Recheck the old unsigned operation; if it was never queued, produce a fresh
operation with the actual Timelock delay. Never load keys or broadcast from the
preparation tool. Preserve a clear distinction between an unsigned proposal and
an applied change.

Verify on a loopback-only Anvil fork of the actual deployed Base contracts that
the fixed floor currently blocks excess allocation, removing only that floor
preserves the ratio, allocation above the remaining buffer still fails, available
capital can reach the strategy, and the buffer can pay an instant redemption and
be replenished from the strategy. Revert local state afterwards. This is a scoped
buffer-path check, not a claim that all excluded readiness risks are resolved.

Applying or queueing the proposal in mainnet requires the user's review of the
concrete tuple, timings and unsigned transaction requests. No mainnet transaction
or capital movement is part of this preparation.

## User approval — 2026-11-09

The user confirmed the concrete minimumBuffer 5 USDC -> 0 transition while
retaining the 10% reserve and all other limits. Queue the reviewed unsigned
operation 0xf70f7c259ff3d458977f4e45a8abc1c67097f146bcf179d314eef044ae6d6841
in the existing Base Timelock after rechecking identities, limits and timing.
Execution of this same approved operation remains subject to its on-chain ETA;
no bypass, unrelated change or service restart is authorized. Record and verify
transaction receipts and the queued/applied distinction. Keep the preparation
utility strictly read-only; use a separate narrow operator for signed submission.

The user then pointed out that the six-hour review margin made the first ETA
longer than one day. Replace that queue with the same setter payload and a
24-hour delay plus a short inclusion margin; cancel the superseded operation
only after the earlier replacement is confirmed. Current operation:
0x1488e32fa0a98607ac9c45fdde681a6dd0ef543eb9ef528f6cf410c577e92e02,
ETA 2026-11-10 18:33:38 UTC. All policy values are identical to the reviewed plan.

## Execution requested and verified — 2026-11-11 Asia/Jerusalem

The user requested "исполняй буфер". Execute only the approved replacement
operation after confirming live identities, exact limits and queue/timing.
Execution succeeded in Base transaction
0x57e04f978215f0c1f770ead7312f72b78e35acc69cc93f73ccb32126c9649d76.
Postconditions verified through two RPCs: fixed minimum zero, 10% ratio and
all other limits preserved, operation unqueued, implementations unchanged.
The configuration change does not itself move funds. Allocation headroom was
checked by read-only simulation; no live capital allocation was submitted.
Evidence: changes/base-buffer-remove-fixed-floor/execution-confirmation.md.

## One-time capital placement requested — 2026-11-11 Asia/Jerusalem

The user subsequently instructed "размести" after reviewing the remaining
5 USDC cash and approximately 54.7% utilization. Place only the newly available
cash into the existing Base ChainAgent/Strategy through pushToAgent and allocate.
Keep the approved 10% reserve and all current limits unchanged. No new provider,
bridge, contract upgrade or automatic allocation job is in scope.

Recheck pending deposits, all withdrawal obligations, allocation pauses,
provider health, actual code/implementation and executor roles before moving
capital. Bound the amount by current available cash minus the required reserve,
with a maximum of 3.90 USDC and a small rounding margin. Simulate both steps on
a fresh local fork before broadcast, then simulate each live call again. Record
transaction hash/nonce before each broadcast and verify both receipts, minted
shares, remaining reserve and zero agent idle via an independent RPC. Never
blindly repeat a step after an ambiguous submission. If the second step fails,
reconcile its transaction first; unallocated agent idle can be returned to the
same hub vault with the existing returnToVault path.

Placement completed: 3.897300 USDC, push tx
0x8fe56f545ee364bc6e171e21d331b60c152e00174ec1559517eb017d56b7b26f,
allocation tx
0x00689e1152d2ef52c4376a37d4fd0fb35a3b47442e8e2771ec624d732f6f39cc.
Both succeeded and were independently verified after a successful fresh local
fork rehearsal. Vault cash 1.102700 USDC exceeds required 1.102620 reserve;
agent idle zero, earning capital 9.923528 USDC, utilization 89.9992%.
Evidence: changes/base-buffer-remove-fixed-floor/allocation-confirmation.md.
