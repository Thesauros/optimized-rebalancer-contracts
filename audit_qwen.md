# Thesauros — Hexens Audit Response

**Audit:** Hexens Security Review, July 2026 (revised)
**Auditor:** Jahyun Koo, Lead Security Researcher
**Scope:** [Thesauros/optimized-rebalancer-contracts @ fd1c874](https://github.com/Thesauros/optimized-rebalancer-contracts/commit/fd1c8747a01732448774ca3bfd6bc6cf2024b5fc)
**Report date:** 20 July 2026 (revised: corrected scope commit)
**Response date:** 21 July 2026
**Response by:** CTO / Thesauros

---

## Summary

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| THES2-1 | Fixed-order withdrawals may fail despite available liquidity | Low | Acknowledged — mitigation planned |
| THES2-3 | Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value | Low | Acknowledged — monitoring + mitigation planned |
| THES2-2 | Provider adapters hardcode Arbitrum protocol addresses | Informational | Not applicable — referenced code does not exist at the audited commit |

Overall: **0 Critical, 0 High, 0 Medium.** Two valid Low findings (both Morpho-specific) and one Informational that does not apply to the audited commit. We consider the audit result strong.

---

## THES2-1 — Fixed-order withdrawals may fail despite available liquidity

**Severity:** Low (Rare / Low)
**Path:** `contracts/Rebalancer.sol` — `_withdraw()` function (L409–L445)

### Finding

The `_withdraw()` function iterates providers in a fixed order and uses `getDepositBalance()` (accounting balance) to determine how much to withdraw from each. With MorphoProvider, `getDepositBalance()` returns the MetaMorpho share-to-asset conversion, which may exceed immediately withdrawable liquidity when borrowing activity reduces available assets. If an earlier provider reverts, the transaction stops before later providers with sufficient liquidity are attempted.

### Verification

Confirmed at `fd1c874`. The `_withdraw()` function:

```solidity
// Rebalancer.sol L409-445
function _withdraw(...) internal {
    _burn(owner, shares);
    uint256 assetsLeft = assets;
    for (uint256 i; i < count; i++) {
        IProvider provider = $._providers[i];
        uint256 assetsAtProvider = provider.getDepositBalance(address(this), this);
        if (assetsAtProvider == 0) continue;
        uint256 amount = (assetsAtProvider >= assetsLeft) ? assetsLeft : assetsAtProvider;
        _delegateActionToProvider(amount, "withdraw", provider);  // ← reverts propagate
        assetsLeft -= amount;
        if (assetsLeft == 0) break;
    }
    // ...
}
```

No try/catch isolation. A revert in any provider blocks the entire withdrawal.

### Response

**Acknowledged.** Valid edge case specific to the Morpho integration.

**Mitigating factors:**

1. **Failed tx restores state.** The revert is atomic — shares are not burned, accounting is not modified. The user loses only gas, not funds.

2. **Operational workaround exists.** The operator can reorder providers via `setProviders()` (timelock-gated) or rebalance funds away from the illiquid Morpho vault before the user retries.

3. **MorphoProvider's internal `_withdrawMorpho` already handles partial liquidity** via try/catch across its withdraw queue. The revert only occurs when the *entire* MetaMorpho vault lacks liquidity — a rare scenario requiring sustained high utilization across all Morpho markets simultaneously.

4. **`maxWithdraw()` and `maxRedeem()` return 0** by design, explicitly signaling to integrators that withdrawable limits depend on external providers and cannot be guaranteed on-chain.

### Planned remediation

Try/catch isolation in `_withdraw()` for the next protocol upgrade:

- Isolate each provider withdrawal so a single provider failure does not block the entire transaction.
- Calculate remaining amount from actual tokens received, not accounting balances.
- Revert only after all providers have been attempted.

**Timeline:** Next scheduled protocol upgrade. Not blocking for current deployment.

---

## THES2-3 — Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value

**Severity:** Low (Rare / Low)
**Path:** `contracts/providers/MorphoProvider.sol` (note: revised report header says `AaveV3Provider.sol` — appears to be a typo, as the code shown is MorphoProvider)

### Finding

MetaMorpho V1.1 records assets lost through realized bad debt as `lostAssets`, which only increases. Since `totalAssets()` includes `lostAssets`, `MorphoProvider.getDepositBalance()` (which uses `convertToAssets()`) may overstate the recoverable position after a material loss. The rate calculation in `getDepositRate()` uses real market assets (`expectedSupplyAssets`) in the numerator but the `lostAssets`-inclusive `totalAssets()` as the denominator.

### Verification

Confirmed at `fd1c874`:

```solidity
// MorphoProvider.sol L120-125
function getDepositBalance(address user, IRebalancer) external view returns (uint256 balance) {
    uint256 shares = _metaMorpho.balanceOf(user);
    balance = _metaMorpho.convertToAssets(shares);  // ← includes lostAssets via totalAssets()
}

// MorphoProvider.sol L131-160
function getDepositRate(IRebalancer) external view returns (uint256 rate) {
    uint256 totalDeposits = _metaMorpho.totalAssets();  // ← includes lostAssets
    for (...) {
        uint256 assetsInMarket = morpho.expectedSupplyAssets(...);  // ← real assets only
        ratio += marketRate.wMulDown(assetsInMarket);
    }
    rate = ratio.mulDivDown(1e18 - _metaMorpho.fee(), totalDeposits) * 10 ** 9;
    //                                                  ^^^^^^^^^^^^^ denominator includes lostAssets
}
```

The inconsistency between numerator (real assets) and denominator (book value including lostAssets) is confirmed.

### Response

**Acknowledged.** Valid accounting subtlety in the MetaMorpho V1.1 integration.

**Mitigating factors:**

1. **`lostAssets` only becomes positive after realized bad debt** — rare in Morpho Blue's overcollateralized lending model.

2. **Morpho's own documentation confirms this behavior.** V1.1 does not immediately allocate realized bad debt across depositors. Our `getDepositBalance()` reflects the same share price that a user would receive on actual withdrawal.

3. **The Rebalancer's `totalAssets()` aggregates across all providers.** A Morpho-specific loss is proportionally diluted across the total TVL.

4. **Operator monitoring.** The team monitors Morpho vault health off-chain. In the event of a material loss: rebalance out, update provider list via timelock, or pause.

5. **Rate calculation bias is conservative.** The denominator (including `lostAssets`) is larger than real assets, making the reported rate *lower* than actual yield. This under-reports rather than over-reports.

### Planned remediation

1. Add a `getWithdrawableBalance()` method deriving recoverable position from real assets.
2. Align `getDepositBalance()` and `getDepositRate()` to the same accounting basis.
3. Emit an event when `lostAssets` increases beyond a threshold.

**Timeline:** Next scheduled protocol upgrade.

---

## THES2-2 — Provider adapters hardcode Arbitrum protocol addresses

**Severity:** Informational (Unlikely / Informational)
**Path (as stated in report):** `AaveV3Provider.sol#L42`, `DolomiteProvider.sol#L49`, `RevertProvider.sol#L33`

### Finding

The Aave V3, Dolomite, and Revert providers embed Arbitrum protocol addresses directly in their implementations.

### Verification at `fd1c874`

| Referenced in report | Actual state at `fd1c874` |
|---------------------|--------------------------|
| `DolomiteProvider.sol#L49` | **File does not exist.** `contracts/providers/` contains only 3 files. |
| `RevertProvider.sol#L33` | **File does not exist.** |
| `AaveV3Provider.sol` address `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` (Arbitrum) | **Actual address: `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`** (Base PoolAddressesProvider, L87) |

The `contracts/providers/` directory at `fd1c874`:
```
AaveV3Provider.sol      ← Base address (0xe20f...)
CompoundV3Provider.sol  ← constructor-injected
MorphoProvider.sol      ← constructor-injected
```

### Response

**Not applicable.** The finding references two files (`DolomiteProvider.sol`, `RevertProvider.sol`) that do not exist at the audited commit, and an Arbitrum address (`0xa976...`) that is not present in `AaveV3Provider.sol` (which uses the Base address `0xe20f...`).

The finding content appears to describe code from a different branch or repository state. We request Hexens either remove this finding or update it to reflect the actual code at `fd1c874`.

**Design note:** The single remaining hardcoded address (`PoolAddressesProvider` in `AaveV3Provider`) follows Aave's recommended integration pattern — a stable registry contract that dynamically resolves the current `Pool` implementation, verified against Aave's official canonical deployment set for Base. For future multi-chain deployments, we will migrate to constructor-injected addresses as already done for Compound and Morpho.

**Status: Not applicable.**

---

## General Remarks

1. **No Critical or High findings.** The protocol's core security model — role-based access, timelock-gated critical operations, fee caps, inflation attack mitigation, and ERC4626 compliance — was validated without significant issues.

2. **Both valid Low findings are Morpho-specific** and relate to edge cases in the MetaMorpho V1.1 integration (liquidity availability and bad debt accounting). These are inherent to the Morpho protocol design and affect all MetaMorpho integrators. Our planned mitigations (try/catch isolation, adjusted accounting) go beyond what most MetaMorpho integrators implement.

3. **THES2-2 references code not present at the audited commit.** The finding cites `DolomiteProvider.sol`, `RevertProvider.sol`, and an Arbitrum address — none of which exist at `fd1c874`. We request Hexens confirm whether this finding should be removed or updated.

4. **THES2-3 path appears to be a typo.** The report header says `AaveV3Provider.sol` but the code shown is from `MorphoProvider.sol`. The finding itself is valid and acknowledged.

5. **Operational safeguards.** The protocol includes pause mechanisms (`PausableActions`), timelock-gated provider management, and operator-controlled rebalancing — multiple layers of defense for the edge cases identified.

---

*Prepared by CTO office, Thesauros. 21 July 2026. All findings verified against code at commit fd1c8747a01732448774ca3bfd6bc6cf2024b5fc.*
