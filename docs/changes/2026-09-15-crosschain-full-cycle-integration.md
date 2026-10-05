# Changes: 2026-09-15 — Crosschain Full-Cycle Integration Tests

**Branch:** `crosschain-sandbox`
**Date:** 2026-09-15
**Author:** cto-agent

## Summary

Added 9 end-to-end integration tests covering the complete crosschain principal
transport cycle: Vault -> MeshProvider -> MeshNode -> Bridge -> MeshCustodian ->
YieldProvider -> Bridge -> MeshNode -> Vault.

## New Files

- `test/crosschain/MeshFullCycle.t.sol` — 9 full-cycle integration tests + DualMeshBridgeAdapter

## What Changed

### DualMeshBridgeAdapter (test fixture)

Bidirectional mock bridge connecting MeshNode (source) and MeshCustodian
(destination) in a single EVM. Key design decisions:

- **Auto-detects direction**: first `send()` per transferId = outbound (node ->
  custodian), second `send()` after delivery = return (custodian -> node).
- **Stores destChainId** from outbound and reuses it as `sourceChainId` for
  return messages, ensuring MeshNode's `receiveReturn` peer verification passes.
- **Fee only on outbound**: return path is fee-free (simulates same bridge
  message carrying the return).
- **Deliver helpers**: `deliverToCustodian()` calls `onBridgeIn` with proper
  token approval; `deliverReturn()` calls `receiveReturn` with approval.

### Test Coverage

| Test | What it proves |
|---|---|
| `testFullCycleWithYieldDeployment` | Complete cycle: bridge out, deploy to yield, simulate yield, withdraw, bridge back principal, verify NAV |
| `testFullCycleWithBridgeFee` | Fee realized once at source, return is fee-free, NAV decreases by exact fee |
| `testFullCyclePartialLoss` | Partial return correctly realizes loss at source |
| `testFullCycleWriteDownAndRecovery` | Write-down + full recovery: book value reconciled, nominal exposure cleared |
| `testCustodianPauseBlocksOperationsDuringReturn` | Guardian pause blocks deploy/bridgeBack; unpause completes cycle |
| `testMultipleVaultsFullCycle` | Two vaults share one node; bridge from vault A doesn't affect vault B |
| `testCustodianYieldDoesNotAffectSourceNAV` | Yield at custodian is invisible to source vault NAV (by design) |
| `testUserWithdrawDuringPendingTransfer` | User can't withdraw more than local liquidity; shares preserved on revert |
| `testEndToEndWithDepositWithdrawDuringBridge` | Deposits go to entryProvider (not mesh); mesh local unchanged during bridge |

## Test Results

```
forge test --no-match-path 'test/forking/*':
  73 tests passed, 0 failed (64 existing + 9 new)
  - 26 MeshNode integration (Mesh.t.sol)
  - 16 MeshCustodian (MeshCustodian.t.sol)
  - 7 adversarial token boundary (MeshTokenBoundary.t.sol)
  - 9 full-cycle integration (MeshFullCycle.t.sol)  <-- NEW
  - 12 Rebalancer regression
  - 3 invariant suites (256 runs each, 128k calls, 0 reverts)

forge build: clean
hardhat compile: clean
```

## Invariants Verified

1. **NAV conservation**: `vault.totalAssets()` preserved through full cycle (minus bridge fees)
2. **No double counting**: custodian yield does not inflate source vault NAV
3. **Vault isolation**: one vault's bridge operations don't affect another's accounting
4. **Exact withdrawal**: short mesh liquidity reverts, user shares preserved
5. **Pause safety**: custodian pause blocks new operations but doesn't trap in-flight returns
6. **Write-down recovery**: written-down transfers can still recover; nominal exposure tracked

## No Changes To

- `contracts/Rebalancer.sol` — unchanged
- `contracts/providers/*` — unchanged
- `contracts/crosschain/MeshNode.sol` — unchanged
- `contracts/crosschain/MeshProvider.sol` — unchanged
- `contracts/crosschain/MeshCustodian.sol` — unchanged
- All existing tests — unchanged, still passing

## Next Steps

- Testnet deployment scripts (Base Sepolia / Arbitrum Sepolia)
- Authenticated bridge adapter (Stargate/LayerZero/CCTP)
- Two-chain testnet rehearsal with manual relay
- Independent QA/security review of full-cycle flow
- Bounded continuous yield accounting (next milestone per spec)
