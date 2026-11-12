# Confirmed placement of released buffer headroom

Change: `base-buffer-remove-fixed-floor`.
User authorization: "размести", after reviewing the remaining 5 USDC vault
cash and the already executed fixed-floor removal. This is a one-time placement
into the existing Base strategy, with no bridge or change to allocation policy.

| Step | Transaction | Successful Base block |
|---|---|---|
| Vault -> existing hub agent, 3.897300 USDC | 0x8fe56f545ee364bc6e171e21d331b60c152e00174ec1559517eb017d56b7b26f | 55800667 |
| Agent -> existing Base strategy, 3.897300 USDC | 0x00689e1152d2ef52c4376a37d4fd0fb35a3b47442e8e2771ec624d732f6f39cc | 55800710 |

The first transaction used nonce 2747 and 189418 gas; the second used nonce
2748 and 387417 gas. The second minted 3876740 strategy-share units to the
ChainAgent. Both receipts have status 1 and the expected matching events.

## Verification

Before signing, two Base RPCs attested four actual proxy implementations and
nine runtime code hashes, unchanged limit tuple, asset/agent/strategy/accountant
identities, executor roles, pauses, current accepted Tick and provider health.
There were no withdrawal liabilities or escrowed redeem shares. Pending deposits
and reserved payouts were zero. The existing entry provider remained
0xDDAA9700c0Da1020AE5dabC7AA0A0bb750DD317c.

The exact push and allocation were first executed on a loopback-only Anvil fork
of Base block 55800441. Postconditions verified the remaining reserve, zero agent
idle, minted strategy shares and the full asset-value increment. The local
snapshot was restored and the fork process stopped. Early local attempts timed
out; one exposed upstream archive-only lookup of an unmined local hash. Explicit
local mining and a fixed local gas price resolved the rehearsal. No mainnet
transaction was sent before the successful rehearsal.

Each live call was then simulated again immediately before submission. Only the
fixed addresses, exact amount and zero ETH value were signed, with conservative
gas/cost bounds and no preexisting pending nonce. A public hash/nonce journal
was saved before each broadcast. Keys and raw signed transactions were never
logged or persisted. State was rechecked between the two confirmed transactions.

Independent RPC verification confirmed both successful receipts, transaction
input/from/to/value, matching receipt block hashes and all final postconditions.
The verification observed 110 confirmations for the push and 70 for allocation.

| Final observed state | USDC |
|---|---:|
| Vault cash | 1.102700 |
| Required reserve (10% of accepted bid NAV) | 1.102620 |
| Extra reserve from rounding | 0.000080 |
| Base ChainAgent idle | 0 |
| Base strategy value owned by the agent | 7.917002 |
| Arbitrum strategy value owned by its agent | 2.006526 |
| Capital earning yield | 9.923528 |
| Cash plus earning capital | 11.026228 |
| Capital utilization | 89.9992% |

Verdict: PASS for the explicitly authorized one-time placement. The fixed floor
remains zero, the ratio remains 10%, every other limit and all implementations
remain unchanged. No automatic allocation job, service rollout, new provider,
bridge transfer or unrelated transaction was installed/submitted. Earlier
statements that capital remained unallocated describe the preceding stage.

Evidence under `ops/governance/`:

- `base-buffer-allocation-20261111.plan.json`
- `base-buffer-allocation-20261111.fork-verification.json`
- `base-buffer-allocation-20261111.push-receipt.json`
- `base-buffer-allocation-20261111.allocate-receipt.json`
- `base-buffer-allocation-20261111.verification.json`

Do not repeat either recorded transaction or reuse the historical amount blindly.
Any future allocation requires fresh cash, reserve, withdrawal and strategy
checks. This change does not provide a global security or scale-readiness claim.
