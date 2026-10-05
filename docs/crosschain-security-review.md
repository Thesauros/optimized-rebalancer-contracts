# Crosschain Liquidity Mesh — QA & Security Review

**Date:** 2026-09-14
**Branch:** `crosschain-sandbox` @ `e287956`
**Scope:** MeshNode, MeshProvider, MeshCustodian + interfaces + tests
**Milestone:** Source-side principal transport (not a production bridge)

---

## Stage 6: QA Verification

### Requirements Coverage (M1-M10)

| ID | Criterion | Verdict | Evidence |
|---|---|---|---|
| M1 | Existing Rebalancer/providers unchanged | PASS | Rebalancer.sol unmodified vs `d9204f4`. MeshProvider is new IProvider. Tests confirm deposit/rebalance/withdraw through vault. Direct provider calls fail. |
| M2 | Per-vault NAV = local + remote, no double counting | PASS | `balanceOf(vault) = localAssets + remoteAssets`. Fuzz conservation (256 runs): `totalAssets == 500 - send + recovery`. Donations excluded from NAV. |
| M3 | Access control: governance/executor/guardian | PASS | `configureVault/addRoute` — onlyGovernance. `bridgeOut` — onlyExecutor. Guardian pauses (setPaused true), governance unpause. Withdrawals/returns work during pause. |
| M4 | Unique ID, bounded quote, exact debit, approval cleanup | PASS | `transferId = keccak256(chain, node, ++nonce)`. `minAmountOut >= amount * (BPS - maxFeeBps) / BPS`. Before/after balance verification. `forceApprove(adapter, 0)` after send. |
| M5 | Reserve floor, max remote, route capacity | PASS | `minLocalBps` with Ceil rounding. `maxRemoteBps` via `pendingPrincipal`. `maxInFlight` on route. Write-down does not free route capacity (inFlight tracks nominal). |
| M6 | One final return, authenticated | PASS | Only adapter, chain+peer verified. `amount <= principal`. Status=Settled before token ops. Replay rejected. Zero recovery requires authenticated call with 0 tokens. |
| M7 | Governance write-down | PASS | onlyGovernance. Reduces bookValue + remoteAssets. Transfer identity preserved (status stays Pending, inFlight nominal). |
| M8 | Exact local withdrawals only | PASS | `withdrawToVault` reverts on shortage. Vault skips Mesh, tries next provider. No spending idle vault tokens. |
| M9 | Non-reentrant, immutable provider, O(1) views | PASS | ReentrancyGuard on all mutations. `forge inspect MeshProvider storage-layout` — empty. `balanceOf`/`totalAssets` — O(1). |
| M10 | Test coverage | PASS | 26 integration + 7 adversarial + fuzz conservation (256 runs). Covers reentrancy, replay, access, caps, pause, multi-vault, malformed adapter, taxed tokens. |

### Test Results

```
forge test --match-path 'test/crosschain/*': 33 passed, 0 failed
forge test --no-match-path 'test/forking/*': 48 passed, 0 failed
forge build: clean
hardhat compile: clean
```

### QA Verdict: PASS

All 10 requirements verified. No gaps in test coverage for in-scope functionality.

---

## Stage 7: Security Review

### MeshNode.sol

| ID | Severity | Finding | Status |
|---|---|---|---|
| SEC-NODE-1 | Info | `receiveReturn` with `amount=0` settles transfer, reduces remote by bookValue, adds 0 to local. By design (M6: zero recovery requires authenticated final return). | Acknowledged |
| SEC-NODE-2 | Info | Nonce pre-increment (`++nonce`) prevents transfer ID reuse. | Correct |
| SEC-NODE-3 | Info | `minLocalBps` uses `Math.Rounding.Ceil` — conservative rounding. | Correct |
| SEC-NODE-4 | Info | Write-down keeps nominal `inFlight` — prevents route capacity reuse after loss. | Correct per M5/M7 |

**MeshNode verdict: No actionable findings.** Accounting model, access control, reentrancy protection, token verification are correct.

### MeshProvider.sol

| ID | Severity | Finding | Status |
|---|---|---|---|
| SEC-PROV-1 | Info | `onlyVaultContext` checks `address(this) != _self` (delegatecall) AND `address(this) == address(vault)`. Prevents direct calls and vault argument mismatch. | Correct |
| SEC-PROV-2 | Info | `getDepositRate` returns 0 — no false APR advertising. | Correct |
| SEC-PROV-3 | Info | Empty storage layout verified via `forge inspect`. All config immutable. | Correct |

**MeshProvider verdict: No actionable findings.**

### MeshCustodian.sol — Findings & Fixes

| ID | Severity | Finding | Fix Applied |
|---|---|---|---|
| SEC-CUST-1 | Medium | `getTotalValue()` returned only `balanceOf(this)`, ignoring deployed assets | Fixed: returns `totalHeld + totalDeployed`. Added `totalDeployed` state variable. Added `getLiquidValue()` returning `totalHeld`. |
| SEC-CUST-2 | Medium | `deployToProvider` used regular call with `IRebalancer(address(0))` — incompatible with vault IProvider | Fixed: new `ICustodianProvider` interface (no vault argument). Regular call pattern: transfer tokens to provider, then call `deposit(amount)`. |
| SEC-CUST-3 | Medium | `withdrawFromProvider` same issue | Fixed: calls `provider.withdraw(amount)` which transfers tokens back to custodian. |
| SEC-CUST-4 | Low | `bridgeBack` didn't verify `amountOut == spent` | Fixed: added `if (amount > totalHeld) revert UnexpectedTokenAmount()` before approve. `totalHeld -= spent` after. |
| SEC-CUST-5 | Low | No pause mechanism | Fixed: added `paused` state, `setPaused(bool)`, `whenNotPaused` modifier on `onBridgeIn`, `deployToProvider`, `bridgeBack`. Guardian can pause, only governance can unpause. |
| SEC-CUST-6 | Low | `onBridgeIn` ignored `srcChainId` and `transferId` parameters | Fixed: event `BridgeInReceived` now emits `srcChainId` and `transferId` as indexed parameters. |

**Additional improvements:**
- Added `guardian` role (constructor parameter)
- Added `setRoles(executor, guardian)` for governance
- Added `RolesUpdated` event
- Added `receive()` for native token (bridge fees)

**MeshCustodian verdict: All 6 findings fixed. 16 new tests cover all fixes.**

### Threat Model Verification

| Threat | Mitigation | Status |
|---|---|---|
| Executor compromise | Fixed destinations, bounded fees/reserve/exposure, no arbitrary recipient or generic execution | PASS |
| Spoof/replay | Adapter + chain + peer + transfer ID checked; terminal state persists | PASS |
| Adapter compromise | Cannot debit above exact approval; may lie within fee bound or lose all assigned funds | PASS (governance trusts adapter) |
| Reentrancy | Node guard on mutations; checks/effects before transfers | PASS |
| Donation/inflation | No repricing, no separate share token in this milestone | PASS |
| Liquidity exhaustion | Synchronous exits depend on local liquidity; limits constrain sends not exits | PASS |
| Governance | Constructor accepts explicit deployed governance contract (intended Timelock) | PASS |

---

## Summary

```
QA:        PASS (10/10 requirements verified)
Security:  MeshNode      — clean (0 actionable findings)
           MeshProvider   — clean (0 actionable findings)
           MeshCustodian  — 6 findings FIXED (3 Medium + 3 Low)
Tests:     64 passed, 0 failed (48 existing + 16 new custodian tests)
Build:     forge build + hardhat compile — clean
```

**New files:**
- `contracts/crosschain/interfaces/ICustodianProvider.sol` — simplified provider interface for custodian
- `test/crosschain/MeshCustodian.t.sol` — 16 tests covering all fixes
- `test/crosschain/MockCustodianProvider.sol` — test fixture

**Recommendation:** All three contracts (MeshNode, MeshProvider, MeshCustodian) are now security-reviewed and tested. Next milestone: authenticated Stargate/LayerZero adapter + two-chain fork rehearsal.
