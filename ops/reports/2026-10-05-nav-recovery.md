# Stand NAV publication incident — 2026-10-05

Tick 113 stopped advancing while RPC reads repeatedly hit Moralis HTTP 429.
Long scans then exceeded the snapshot's submission window. The scanner also
mistook rate-limit errors for block-range errors and reduced its global range,
increasing the number of requests on later scans.

## Changes (services only)

- `a4cafc1`: distinguish throttling from log-range limits; bound retries and request starts.
- `1f328aa`: checkpoint completed scan batches, share the operators transfer index,
  and finish historical catch-up before selecting a snapshot reference.
- `a8765ed`: use weighted RPC budgets (operators 40 CU/s, indexer 24 CU/s,
  monitor 12 CU/s). Moralis charges log/archive requests at 12 CU.
- `6252fdf`: discover keeper requests through the vault's contiguous request IDs,
  eliminating a full log replay on every restart.
- `1078907`: persist monitor governance history with deployment-bound cache keys
  and a restart rewind.
- `a761412`: prevent monitor/verification readers from overwriting operator
  transfer checkpoints with older progress.
- `e53dc59`: pin the previously authorized buffer timer to the RPC recovery build.

RPC cost reference: https://docs.moralis.com/rpc-nodes/pricing

No Solidity, deployed addresses, production profile, allocator execution mode,
or frontend code changed. Env files remain untracked with mode 600.

## Validation

- 54 ops tests: 46 passed, 8 skipped (compiled ABI artifacts / Anvil absent).
- Typecheck remains blocked by existing local dependency/type resolution:
  `deploy/crosschain/registry.ts` cannot resolve `ethers`; installed Node types
  do not declare `node:sqlite`. No additional compiler errors appeared.
- Final preflight: PASSED, zero FAIL and WARN. An intermediate attempt under
  concurrent catch-up load failed with HTTP 429; it was not bypassed. After
  separating range handling and reducing/weighting the budgets, it passed.
- Operators accepted tick **114**, logged at **2026-10-05 12:56:19 UTC**:
  rateBid **1.000236182612614242 USDC/share**, NAV **11.002561 USDC**.
  Transaction: `0x7f584ed1190afd18067d3e506ed37df61b6a36c7df759cd1806f6f42156f18ab`.
- Public `/v1/vault` returns 200 with tick 114 and `tcUSDC-stand`.
- Public `/health` recovered to 200 / healthy=true at 12:57:50 UTC.
- `/v1/activity?limit=5`: 200, five events. `/v1/allocation`: 200,
  Base 8453 hub and Arbitrum 42161 spoke.
- Frontend `/live`: 200 with both expected headings.
- NAV, keeper, relayer and allocator health: 200; operators container healthy.
- Monitor is still rebuilding governance/verification history and reports 503
  during that work. It must not be reported as healthy until a complete pass.

Post-tick `exec status`: accepted 114, frozen=false, quarantined=false,
hub sends allowed=true. Vault cash/free/buffer 5 USDC, pending deposits,
liabilities and reserves zero, shares 10.999963. Base strategy 4.001487 USDC,
Arbitrum strategy 2.001075 USDC; both providers healthy, both agents idle zero.
Signer ETH: Base **0.00563894662870676**, Arbitrum **0.00438507593645782**.
No operator iteration failures observed after the weighted-budget deployment
at 12:49 UTC through acceptance checks. Hourly recurrence has not yet been
observed for a full hour; do not infer it from one successful publication.

## Already scheduled buffer change

`xc-buffer-5pct.timer` remains enabled for **2026-10-05 22:05 UTC**, after the
on-chain timelock ETA. Current 5 USDC buffer remains active until execution;
its target is fixed buffer zero plus 5% of NAV. See `../governance/README.md`.
The allocator remains in propose mode.
