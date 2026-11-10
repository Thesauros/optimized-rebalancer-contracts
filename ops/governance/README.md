# Base buffer review

The 2026-11-09 review concerns only the fixed 5 USDC minimum. The proposed change
preserves the current 10% ratio and every other live limit. Preparation is
read-only; JSON files contain unsigned requests, not executed transactions.

Use `ops/src/prepare-buffer-10pct.ts prepare FILE` for a fresh proposal or
`check FILE` to re-read its status and simulate the currently permitted action.
Both commands reject signing/broadcast methods and do not load keys. Check the
actual limits and queue/execution deadlines again before signing externally.

Do not use `buffer-governance.ts` for this proposal: that separate legacy tool
targets a 5% ratio. Do not assume the old October unsigned plan was queued.

## Current submitted operation

User approved the fixed-floor removal on 2026-11-09. The active plan is
`base-buffer-10pct-20261109-24h.json`, operation
`0x1488e32fa0a98607ac9c45fdde681a6dd0ef543eb9ef528f6cf410c577e92e02`.
Queue transaction:
`0x4aa147f95d5b36cbe40ccbd978c99a74c3db4ecf826d162457b6617af851fef4`.
Execute no earlier than 2026-11-10 18:33:38 UTC (20:33:38 Asia/Jerusalem).

The original November 9 operation ending `6841` was queued with an unnecessary
six-hour review margin, then cancelled when the user corrected the timing.
Cancellation: `0x12a70fef6db588a246417a35263217b95ef39e8688d928cf25d35b94319962fd`.
Keep that plan and its receipts as history; do not resubmit or execute it.

Before executing the active plan, run the read-only `check FILE`, verify the
operation is queued and executable, governance/code identities still match,
and all current limits still equal the approved before tuple. Send only its
exact unsigned execute request from the existing authorized owner. No new
approval is needed for this same confirmed change; drift requires review.
After execution verify only minimumBuffer changed to zero, minBufferRatio is
still 10%, and the operation is no longer queued. Queueing alone does not apply
the new limit or allocate capital. No automatic execution job was installed.

## Execution confirmed — 2026-11-11 Asia/Jerusalem

The user requested execution ("исполняй буфер"). The exact approved operation
was executed in Base transaction
`0x57e04f978215f0c1f770ead7312f72b78e35acc69cc93f73ccb32126c9649d76`,
block 55791865. Receipt status is 1. Primary and independent RPC checks confirm
minimumBuffer is 0, minBufferRatio remains 10%, the other seven tuple fields
are unchanged, and the executed operation is no longer queued. The cancelled
original operation remains unqueued; proxy implementation/code are unchanged.

At verification block 55792151: cash 5 USDC, pending deposits/liabilities/reserved
all zero, accepted bid NAV 11.026204 USDC, required reserve 1.102620 USDC, and
allocation headroom 3.897380 USDC. A read-only pushToAgent simulation for that
headroom passed. No actual USDC allocation or service rollout was submitted.

Evidence: `base-buffer-10pct-20261109-24h.execute-receipt.json` and
`base-buffer-10pct-20261109-24h.execution-verification.json`. Do not execute or
requeue this operation again. See
`changes/base-buffer-remove-fixed-floor/execution-confirmation.md` for the
scoped verification record.
