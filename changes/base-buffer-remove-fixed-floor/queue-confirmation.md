# Confirmed queue and timing correction

Change: `base-buffer-remove-fixed-floor`.
User approved the reviewed buffer transition on 2026-11-09, then noted
"это больше суток". The extra review margin was removed while preserving the
approved policy and the contract's mandatory delay.

| Operation | Transaction | Result |
|---|---|---|
| Initial queue, ETA Nov 11 00:15 UTC | 0xccf4271a23ba9a8eec6c5d5ecd2da36426e18014a061264b0dbda441895ecd22 | Confirmed, subsequently cancelled |
| Replacement queue | 0x4aa147f95d5b36cbe40ccbd978c99a74c3db4ecf826d162457b6617af851fef4 | Confirmed at Base block 55292888 |
| Cancel initial operation | 0x12a70fef6db588a246417a35263217b95ef39e8688d928cf25d35b94319962fd | Confirmed at Base block 55293122 |

Active operation:
`0x1488e32fa0a98607ac9c45fdde681a6dd0ef543eb9ef528f6cf410c577e92e02`.
ETA: **2026-11-10 18:33:38 UTC**, **20:33:38 Asia/Jerusalem**.
Actual queue inclusion: 2026-11-09 18:29:13 UTC.
Delay: **86665 seconds = 24 hours 4 minutes 25 seconds**.
The contract's required 86400-second delay was not changed or bypassed.

The replacement's setter payload is byte-for-byte identical to the approved
payload: minimumBuffer 5 USDC -> 0, minBufferRatio stays 10%, all other seven
tuple fields unchanged. Signed requests were limited to the existing owner,
Base chain id 8453, the manifest Timelock, zero ETH value, the exact operation
and a conservative gas-cost bound. Signer material was never logged or stored.
All three receipts and postconditions were checked. A second public Base RPC
independently confirmed the replacement/cancellation receipts and queued state.

Current status: **queued, not executed**. The original operation is not queued;
the replacement is queued; live limits still contain the fixed 5 USDC floor.
No USDC allocation, contract upgrade, service restart or other limit change.
No automatic execution job was installed. The same operation's execution after
ETA is already authorized; verify unchanged limits/governance and canonical
queue state first. Do not resubmit or execute the superseded operation.

Evidence: `ops/governance/base-buffer-10pct-20261109.queue-receipt.json`,
`base-buffer-10pct-20261109-24h.queue-receipt.json`,
`base-buffer-10pct-20261109.cancel-original-receipt.json`, and
`base-buffer-10pct-20261109-24h.verification.json`.
