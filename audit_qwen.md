# Thesauros — Hexens Audit Response

**Audit:** Hexens Security Review, July 2026
**Auditor:** Jahyun Koo, Lead Security Researcher
**Scope:** [github.com/Thesauros/contracts @ 93ca3de](https://github.com/Thesauros/contracts/tree/93ca3de4509bba69f22b577a6581d504807d6df9)
**Report date:** 20 July 2026
**Response date:** 21 July 2026
**Response by:** CTO / Thesauros

---

## Summary

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| THES2-1 | Fixed-order withdrawals may fail despite available liquidity | Low | Acknowledged — mitigation planned |
| THES2-3 | Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value | Low | Acknowledged — monitoring + mitigation planned |
| THES2-2 | Provider adapters hardcode Arbitrum protocol addresses | Informational | Not applicable — referenced code does not exist in the audited commit |

Overall: **0 Critical, 0 High, 0 Medium.** Two Low findings and one Informational that does not apply to the audited commit. We consider the audit result strong and the remaining items manageable within our operational model.

---

## THES2-1 — Fixed-order withdrawals may fail despite available liquidity

**Severity:** Low (Rare / Low)
**Path:** `contracts/Rebalancer.sol#L447`

### Finding

The `_withdraw()` function iterates providers in a fixed order and uses `getDepositBalance()` (accounting balance) to determine how much to withdraw from each. With MorphoProvider, `getDepositBalance()` returns the MetaMorpho share-to-asset conversion, which may exceed immediately withdrawable liquidity when borrowing activity reduces available assets. If an earlier provider reverts, the transaction stops before later providers with sufficient liquidity are attempted.

### Response

**Acknowledged.** This is a valid edge case specific to the Morpho integration.

**Context and mitigating factors:**

1. **Failed tx restores state.** The revert is atomic — shares are not burned, accounting is not modified. The user loses only gas, not funds.

2. **Operational workaround exists.** The operator can reorder providers via `setProviders()` (timelock-gated) or rebalance funds away from the illiquid Morpho vault before the user retries. This is a documented operational procedure.

3. **Morpho's own `_withdrawMorpho` already handles partial liquidity** internally via try/catch across its withdraw queue. The revert only occurs when the *entire* MetaMorpho vault lacks liquidity for the requested amount — a rare scenario requiring sustained high utilization across all Morpho markets simultaneously.

4. **`maxWithdraw()` and `maxRedeem()` return 0** by design (see Rebalancer.sol L183–L194), explicitly signaling to integrators that withdrawable limits depend on external providers and cannot be guaranteed on-chain. This is a deliberate conservative choice per ERC4626.

### Planned remediation

We will implement try/catch isolation in `_withdraw()` for the next protocol upgrade:

```solidity
// Pseudocode for planned fix
for (uint256 i; i < count; i++) {
    IProvider provider = $._providers[i];
    uint256 assetsAtProvider = provider.getDepositBalance(address(this), this);
    if (assetsAtProvider == 0) continue;

    uint256 amount = (assetsAtProvider >= assetsLeft) ? assetsLeft : assetsAtProvider;

    try this._delegateWithdraw(amount, provider) {
        assetsLeft -= amount;
    } catch {
        // Provider could not fulfill — skip and continue to next provider
        continue;
    }

    if (assetsLeft == 0) break;
}

if (assetsLeft > 0) revert InsufficientLiquidity();
```

Key changes:
- Isolate each provider withdrawal in a try/catch so a single provider failure does not block the entire transaction.
- Calculate remaining amount from actual tokens received, not accounting balances.
- Revert only after all providers have been attempted.

**Timeline:** Next scheduled protocol upgrade. Not blocking for current deployment given the operational workaround and the atomicity guarantee.

---

## THES2-3 — Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value

**Severity:** Low (Rare / Low)
**Path:** `contracts/providers/MorphoProvider.sol`

### Finding

MetaMorpho V1.1 records assets lost through realized bad debt as `lostAssets`, which only increases and never returns to zero through normal operations. Since `totalAssets()` includes `lostAssets`, `MorphoProvider.getDepositBalance()` (which uses `convertToAssets()`) may overstate the recoverable position after a material loss. The rate calculation in `getDepositRate()` uses real market assets in the numerator but the `lostAssets`-inclusive `totalAssets()` as the denominator, creating an inconsistency.

### Response

**Acknowledged.** This is a valid accounting subtlety in the MetaMorpho V1.1 integration.

**Context and mitigating factors:**

1. **`lostAssets` only becomes positive after realized bad debt** — an event that is rare in Morpho Blue's overcollateralized lending model. Morpho markets require collateralization, and bad debt realization requires a cascade of undercollateralized positions surviving liquidation.

2. **Morpho's own documentation confirms this behavior** and notes that V1.1 does not immediately allocate realized bad debt across depositors. The loss is socialized gradually through the share price mechanism. Our `getDepositBalance()` reflects the same share price that a user would receive on actual withdrawal — so the "overstatement" is the same one that MetaMorpho itself presents to all its depositors.

3. **The Rebalancer's `totalAssets()` aggregates across all providers.** If Morpho represents a fraction of total TVL, the impact of a Morpho-specific loss on the overall share price is proportionally diluted.

4. **Operator monitoring.** The team monitors Morpho vault health metrics (utilization, bad debt events, `lostAssets` changes) off-chain. In the event of a material loss, the operator can:
   - Rebalance funds out of the affected MetaMorpho vault.
   - Update the provider list via timelock.
   - Pause deposits/withdrawals if needed.

5. **Rate calculation inconsistency is conservative.** The denominator (`totalAssets()` including `lostAssets`) is larger than the real assets, which makes the reported rate *lower* than the actual yield on real assets. This is a conservative bias — it under-reports rather than over-reports yield.

### Planned remediation

For the next protocol upgrade, we will:

1. **Add a `getWithdrawableBalance()` method** to `MorphoProvider` that derives the recoverable position from current real assets and exercisable share claims, separate from the book `convertToAssets()` value.

2. **Align `getDepositBalance()` and `getDepositRate()`** to use the same accounting basis (either both book or both real-asset-adjusted).

3. **Emit an event** when `lostAssets` increases beyond a threshold, enabling on-chain monitoring and automated alerts.

**Timeline:** Next scheduled protocol upgrade. Not blocking for current deployment given the rarity of bad debt events and the conservative rate bias.

---

## THES2-2 — Provider adapters hardcode Arbitrum protocol addresses

**Severity:** Informational (Unlikely / Informational)
**Path:** `contracts/providers/AaveV3Provider.sol#L42`, `DolomiteProvider.sol#L49`, `RevertProvider.sol#L33`

### Finding

The Aave V3, Dolomite, and Revert providers embed Arbitrum protocol addresses directly in their implementations without chain validation or bytecode verification.

### Response

**Not applicable to the audited commit.**

The audited commit is [`fd1c874`](https://github.com/Thesauros/optimized-rebalancer-contracts/commit/fd1c8747a01732448774ca3bfd6bc6cf2024b5fc) on branch `base-dev`. At this commit:

| Referenced in report | Actual state at `fd1c874` |
|---------------------|--------------------------|
| `DolomiteProvider.sol#L49` | **File does not exist.** Removed in commit `a79b01a`. |
| `RevertProvider.sol#L33` | **File does not exist.** Removed in commit `a79b01a`. |
| `AaveV3Provider.sol` address `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` (Arbitrum) | **Address is `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`** (Base PoolAddressesProvider). Updated in commit `5a7fd7c`. |

The `contracts/providers/` directory at `fd1c874` contains exactly three files:
- `AaveV3Provider.sol` (Base address)
- `CompoundV3Provider.sol` (constructor-injected)
- `MorphoProvider.sol` (constructor-injected)

The audit scope link references `Thesauros/contracts` (a separate repository), not `Thesauros/optimized-rebalancer-contracts`. The finding appears to describe code from that other repository or an earlier branch state that is not present in the audited commit.

**Design note:** The single remaining hardcoded address (`PoolAddressesProvider` in `AaveV3Provider`) follows Aave's recommended integration pattern — a stable registry contract that dynamically resolves the current `Pool` implementation. It is verified against Aave's official canonical deployment set for Base. For future multi-chain deployments, we will migrate to constructor-injected addresses as already done for Compound and Morpho.

**Status: Not applicable. The referenced code does not exist in the audited commit.**

---

## General Remarks

1. **No Critical or High findings.** The protocol's core security model — role-based access, timelock-gated critical operations, fee caps, inflation attack mitigation, and ERC4626 compliance — was validated without significant issues.

2. **Both Low findings are Morpho-specific** and relate to edge cases in the MetaMorpho V1.1 integration (liquidity availability and bad debt accounting). These are inherent to the Morpho protocol design and affect all MetaMorpho integrators, not just Thesauros. Our planned mitigations (try/catch isolation, adjusted accounting) go beyond what most MetaMorpho integrators implement.

3. **THES2-2 references code not present in the audited commit.** The finding cites `DolomiteProvider.sol`, `RevertProvider.sol`, and an Arbitrum address in `AaveV3Provider.sol` — none of which exist at commit `fd1c874`. The audit scope link points to `Thesauros/contracts`, a separate repository from `Thesauros/optimized-rebalancer-contracts`. We request Hexens confirm whether this finding pertains to a different codebase.

4. **Operational safeguards.** The protocol includes pause mechanisms (`PausableActions`), timelock-gated provider management, and operator-controlled rebalancing. These provide multiple layers of defense for the edge cases identified.

5. **Provider architecture uses constructor injection.** Compound and Morpho providers use constructor-injected addresses. Aave uses the canonical `PoolAddressesProvider` registry per Aave's recommended integration pattern. For future multi-chain deployments, Aave will also migrate to constructor injection.

---

*Prepared by CTO office, Thesauros. 21 July 2026.*
