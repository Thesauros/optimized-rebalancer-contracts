# Confirmed Base buffer execution

Change: `base-buffer-remove-fixed-floor`.
User instruction: "исполняй буфер". This executes the previously approved
operation without changing its scope or payload.

| Evidence | Result |
|---|---|
| Operation | 0x1488e32fa0a98607ac9c45fdde681a6dd0ef543eb9ef528f6cf410c577e92e02 |
| Transaction | 0x57e04f978215f0c1f770ead7312f72b78e35acc69cc93f73ccb32126c9649d76 |
| Chain / receipt | Base 8453, status 1, block 55791865 |
| Receipt block hash | 0x69c2008aae0e7762b9ad9e9cb868201f599baca4b7eb726f108879299eee9813 |
| Confirmation recorded | 2026-11-10 22:12:29 UTC / 2026-11-11 00:12:29 Asia/Jerusalem |
| Actual gas used | 72786 |
| Independent verification | Same successful receipt block hash; 298 confirmations at verification |

Before signing, the unsigned checker and a separate narrow operator verified
Base identity, owner, Timelock timing, active queue, cancelled original queue,
exact before tuple, active proxy implementation and four runtime code hashes.
Both RPCs successfully simulated the exact Timelock execute call. The operator
independently reconstructed the approved setter calldata, operation hash and
execute request; it enforced zero ETH value and conservative gas/cost bounds.
Signer material and signed transaction bytes were never logged or persisted.
A public journal containing transaction hash and nonce was written before
broadcast to prevent a blind retry. No other transaction was submitted.

## Acceptance verification

| Requirement | Observed result |
|---|---|
| Remove fixed 5 USDC floor | limits.minimumBuffer = 0 |
| Preserve percentage reserve | limits.minBufferRatio = 100000000000000000 (10%) |
| Preserve all other limits | Other seven fields byte-for-byte equal approved before tuple |
| Execute approved operation | Exactly one matching Timelock Executed event; queued = false |
| Preserve cancelled history | Superseded original operation remains unqueued |
| Preserve implementation | Active implementation and runtime hashes still match manifest |
| Verify independently | Mainnet Base and publicnode RPCs agree on receipt and limits |

At verification block 55792151, accepted tick 570 was unfrozen and allocation
was unpaused. Vault token balance and accounting cash were both 5 USDC;
pending deposits, liabilities and reserved payouts were all zero. Accepted bid
NAV was 11.026204 USDC. The live minimumBuffer() returned 1.102620 USDC,
exactly floor(10% of bid NAV), leaving 3.897380 USDC allocation headroom.
An eth_call from the existing executor successfully simulated pushToAgent for
that exact headroom. This is read-only evidence that the fixed-floor allocation
restriction was removed; no actual pushToAgent or strategy allocation was sent.

Verdict: PASS for the approved buffer configuration change and its live
postconditions. Earlier local deployed-bytecode fork verification of reserve,
allocation, instant payout and recall remains recorded in verification.md.
No service restart/rollout, contract upgrade, key/role change or other limit
change was performed. Excluded readiness findings remain outside this change.

Public evidence:
`ops/governance/base-buffer-10pct-20261109-24h.execute-receipt.json` and
`ops/governance/base-buffer-10pct-20261109-24h.execution-verification.json`.

The user later separately instructed "размести". The previously unallocated
headroom was then placed into the existing Base strategy. See
`allocation-confirmation.md` and the `base-buffer-allocation-20261111` records;
the no-capital-movement statements above describe the configuration-only stage.
