# Crosschain liquidity mesh: principal transport milestone

Change: `crosschain-liquidity-mesh`

## Scope and decision

Continue local implementation on `crosschain-sandbox` from `d9204f4`, which
already includes `security/audit-remediation`. The 2026-09-14 continuation
request authorizes implementation; it does not approve a production rollout.
Reuse the existing opportunity research and design spike in the project skills.
This milestone implements the source-side accounting and transport boundary;
it is **not a production bridge or a complete crosschain yield strategy**.

| Alternative | Decision for this milestone |
| --- | --- |
| Mesh as an `IProvider` for existing Meridian vaults | Implement; preserves the vault entry point and existing provider code. |
| Separate legacy CrossChainVault with asynchronous redemption | Do not import; changes the share class and redemption model. |
| Deposit-holder connector (as on the Tron branch) | Does not expose remote positions to the existing vault's provider accounting. |

Use a non-upgradeable `MeshNode` and a stateless delegatecall `MeshProvider`.
Keep separate local and remote principal balances per vault. Shared node shares,
cross-vault buffer borrowing, yield accrual, netting and remote deployment into
lending markets are later milestones. This avoids silently settling one vault's
bridge fees/losses against another vault. APR is explicitly zero for now.

The initial transport is a delayed **test-only adapter**. No live Stargate,
LayerZero, CCTP, remote custodian, oracle, mainnet addresses or deployment script
are included. The eventual adapter must authenticate bridge messages and map
their origin to the configured chain and peer before calling `receiveReturn`.

## Requirements

| ID | Acceptance criterion |
| --- | --- |
| M1 | Existing Rebalancer and providers are unchanged. Normal deposit, rebalance into/out of Mesh and withdrawal work through the actual vault. Direct or mismatched provider calls fail. |
| M2 | Per-vault NAV equals accounted local principal plus booked remote principal. Depositing/bridging/returning never counts principal twice. Donations do not change NAV. One vault cannot debit another. |
| M3 | Only governance registers vaults, immutable route endpoints and limits. Only executor sends. Guardian can immediately pause deposits/outbound sends; governance alone resumes. Withdrawals and returns remain available during pause or route/vault disablement. |
| M4 | A send binds a unique ID to source chain/node/nonce, vault, route, destination and quoted principal. Quote is bounded by caller minimum and governance fee cap. Measure exact token debit; approve adapter only for this call and clear it afterwards. Failed sends roll back all accounting. |
| M5 | Enforce local reserve floor, maximum remote exposure per vault and aggregate nominal exposure per route. Written-down but unresolved transfers still consume route capacity. Endpoints cannot be replaced under pending transfers. |
| M6 | Accept one final principal return per transfer, only from its registered adapter and matching remote chain/peer. Pull tokens from adapter and measure receipt; reject missing funds, excess principal, unknown IDs and replay. Settlement removes booked remote principal and credits actual received principal, realizing losses. Partial cash recovery closes the transfer; it is not a partial settlement. |
| M7 | Governance may reduce a pending transfer's book value with an explicit reason; executor/guardian cannot. Later physical recovery is attributed to the same vault. Never clear transport identity/replay protection on write-down. |
| M8 | Exact local withdrawals only. Insufficient Mesh liquidity reverts the provider call; the existing vault can skip it and try other providers. User withdrawal failure rolls back shares and all provider movements. No spending idle vault tokens to disguise a short Mesh rebalance withdrawal. |
| M9 | All node state changes are non-reentrant. Provider has only immutable configuration and no mutable storage. Views are O(1), never query a remote chain/adapter, and fit the vault's provider-view gas allowance. |
| M10 | Deterministic delayed-delivery tests cover NAV before/after relay, fees, loss, replay, access, caps, pause, multiple vaults, malformed adapter responses and reentrant callbacks. Add fuzz conservation checks and run existing offline regression/invariant suites. |

## Accounting

`balanceOf(vault) = localAssets[vault] + remoteAssets[vault]`.

Sending `amount` and receiving a bridge quote `credited` reduces local by
`amount`, increases remote by `credited` and immediately realizes
`amount - credited` as a bridge cost. Remote principal covers the entire pending
cycle, including outbound delivery, remote custody and return transit.

A final return of `received <= quotedPrincipal` reduces remote by the transfer's
remaining book value and increases local by `received`. Zero recovery requires
an authenticated final return with zero tokens; a mere keeper timeout cannot
erase or settle a transfer. In-flight records remain queryable after settlement.

Deposits transfer tokens from the vault using the delegatecalled provider,
then atomically credit the node. The node cannot `transferFrom` a vault despite
the approval issued by Rebalancer. Only governance-trusted registered vault code
may credit its own deposits; arbitrary vault contracts must not be registered.
Pre-existing unaccounted donations stay outside NAV and are not sweepable here.

## Correction to the discovery spike

`Rebalancer._delegateActionToProvider` ignores a returned boolean. Its rebalance
withdraw/deposit pair uses the requested amount without measuring actual receipt.
A soft partial Mesh withdrawal is therefore unsafe as a generic integration
contract. This milestone uses an exact withdrawal which reverts on shortage.
With Mesh last in the provider order (required operating configuration), this
preserves the user outcome: the vault succeeds precisely when the remaining
request fits the Mesh local buffer. It also prevents an executor consuming an
unaccounted idle vault balance to disguise a short Mesh withdrawal.

## Threat model and limits

- Executor compromise: fixed destinations, bounded fees/reserve/exposure; no arbitrary token recipient or generic execution function.
- Spoof/replay: adapter + chain + peer + transfer identity checked before token settlement; terminal state persists.
- Adapter compromise: cannot debit above exact approval but may lie within its configured fee bound or lose all assigned funds. Governance must trust/audit adapter code. Local mocks do not validate any real bridge's authentication.
- Reentrancy: node guard on mutations; checks/effects precede transfers. Vault integration requires the already merged reentrancy remediation.
- Donation/inflation: no donation-based repricing and no separate Mesh share token in this milestone.
- Liquidity exhaustion: synchronous exits depend on actual local liquidity. Limits constrain sends, not user exits. Stop new sends, recall funds, and use the existing vault pause runbook if necessary.
- Governance: constructor accepts an explicit deployed governance contract (intended Timelock). Deploy/configure through the existing timelock; this layer cannot prove the governance contract actually enforces a delay.
- Economic limitation: no yield or residual remote profits are recognized. Do not allocate live interest-bearing positions with this milestone. Recovery after a write-down can change NAV discontinuously; production recovery needs the future accrual/reconciliation policy.

## Validation and subsequent work

Run `forge test --match-path 'test/crosschain/*'`,
`forge test --no-match-path 'test/forking/*'`, `forge build`,
`./node_modules/.bin/hardhat compile` and `./node_modules/.bin/tsc --noEmit`.
Fork/live bridge tests are separate evidence and must not be claimed from mocks.

Next: bounded continuous yield accounting and reconciliation; remote custodian
integration with existing lending providers; authenticated Stargate/LayerZero
adapter for Base/Arbitrum; actual two-chain fork/testnet rehearsal; independent
QA/security review and founder-approved canary policy before any live deployment.
