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
