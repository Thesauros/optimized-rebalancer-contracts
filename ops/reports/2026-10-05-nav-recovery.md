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
- At 17:49 UTC all six health endpoints (8081–8085, 8090) returned 200;
  operators and monitor containers healthy. Monitor independently reproduced
  the last 50 ticks (`tick.verify=ok`). Only expected standMode warnings and the
  pending authorized buffer timelock warning remain.
- Independent CLI verification: `tick 114: REPRODUCED`.
- Further accepted ticks: 115 at 13:13, 116 at 14:14, 117 at 15:14,
  118 at 16:15, 119 at 17:15 UTC. The hourly cadence is now observed.
  Tick 119 rateBid: 1.000245728099267242 USDC/share, NAV 11.002666 USDC.
  Transaction: `0x13e2c0297dfec7f82f26e1900a357bff4b8b0ceba034dd2c5e3dfd1a45dd0174`.

Post-tick `exec status`: accepted 114, frozen=false, quarantined=false,
hub sends allowed=true. Vault cash/free/buffer 5 USDC, pending deposits,
liabilities and reserves zero, shares 10.999963. Base strategy 4.001487 USDC,
Arbitrum strategy 2.001075 USDC; both providers healthy, both agents idle zero.
Signer ETH: Base **0.00563894662870676**, Arbitrum **0.00438507593645782**.
No NAV/RPC iteration failures observed after the weighted-budget deployment
through 17:49 UTC. Keeper had three `transaction execution reverted` failures:
`0x88417d127b24679dfee206fd998747e98a033e8f2f88fec228e6072345f4e581`,
`0x5a2904b172525b5cae25fffb550df7106a6a1857d5f9b9474cc38fb2b318bc80`,
`0xee707e18e4fe7c0a2cfa3eb725f2ea66f9360c0984250ab737b3389ea27d01f9`.
The last is `clearDeposits`: gas limit 99502, gas used 97853. Read-only replay
at block 52215605 fails with that gas limit and succeeds with twice the gas.
Stand `TX_GAS_MARGIN_BPS` was raised to 10000 (2x the RPC estimate). This
increases the allowed gas, not the amount spent on a successful execution.
The keeper recovered after those failures; no pending deposits/liabilities
remained at the acceptance check.

## Already scheduled buffer change

`xc-buffer-5pct.timer` remains enabled for **2026-10-05 22:05 UTC**, after the
on-chain timelock ETA. Current 5 USDC buffer remains active until execution;
its target is fixed buffer zero plus 5% of NAV. See `../governance/README.md`.
The allocator remains in propose mode.
