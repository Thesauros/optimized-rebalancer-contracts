# Stand buffer change, 2026-10-04

Owner-approved target: fixed buffer 0 USDC, proportional buffer 5% of accepted NAV.
This targets approximately 95% utilization when there are no pending withdrawals.
The other six EpochVault limits are preserved exactly. Contract bytecode and deployment
addresses are unchanged; production profile parameters are unchanged.

The registry contains the target values. The existing Base deployment retains its previous
5 USDC / 10% limits **until Timelock execution confirms**.

Public plan: `base-buffer-5pct.json` (no credentials).
Queue transaction: `0x2928a74a9e03032cfde5159cf56f66751cf746099b669d432decda9f3f217b94`.
Timelock ETA: **2026-10-05 22:04:01 UTC**.
Server timer `xc-buffer-5pct.timer`: **2026-10-05 22:05:00 UTC**, persistent across reboot.

The timer invokes `ops/scripts/execute-buffer-governance.sh` with the immutable image
`sha256:26ac621dfb8146898a6a630c37c41bbf4c9e62ef157cc356f80a7f952765b0dd`.
Do not prune this image before the operation completes.
It stops operators while using the shared signer and restarts them afterwards, even on
failure. Keys remain in `ops/.env.keys`; Docker supplies them as environment variables.

The script verifies the queued calldata and unchanged starting limits, simulates execution,
executes it, verifies the new limits, and then simulates/sends push and Base allocation.
Allocation requires a fresh accepted tick, healthy providers, no queued/owed withdrawals,
and at most 100 USDC per operation. It never retries a failed transaction automatically.
If these checks fail after governance executes, the new buffer stays active and capital
stays liquid until the cause is resolved. The allocator remains in propose mode.

Runtime receipts and completion state: `/data/buffer-5pct-plan.json` in `ops_ops-data`.
Inspect with `journalctl -u xc-buffer-5pct.service` and the governance CLI `status`.
The checked-in JSON is the immutable record of the original queue operation; the runtime
file gains execution, push and allocation transaction hashes as they are sent.

Validation: ops tests, target-call simulation from the Timelock address, queue simulation,
and preflight (passed with zero warnings). The contract enforces the 24 hour delay.
