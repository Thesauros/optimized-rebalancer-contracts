# Thesauros - Hexens July 2026 Audit Response

**Report:** `audit/hexens-thesauros-jul-26(Confidential).pdf`  
**Report date:** 20 July 2026  
**Source-of-truth commit:** [`fd1c8747a01732448774ca3bfd6bc6cf2024b5fc`](https://github.com/Thesauros/optimized-rebalancer-contracts/commit/fd1c8747a01732448774ca3bfd6bc6cf2024b5fc) (`base-dev`)  
**PDF internal scope reference:** `github.com/Thesauros/contracts/tree/93ca3de4509bba69f22b577a6581d504807d6df9`  
**Response date:** 21 July 2026  
**Prepared by:** Codex technical review

## Summary

| ID | Severity | Audit finding | Response status |
| --- | --- | --- | --- |
| THES2-1 | Low | Fixed-order withdrawals may fail despite available liquidity | Accepted, fix required |
| THES2-3 | Low | Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value | Accepted, fix required |
| THES2-2 | Informational | Provider adapters hardcode Arbitrum protocol addresses | Resolved for source-of-truth commit; hardening recommended |

The report contains no Critical, High, or Medium findings. The two Low findings remain relevant because current accounting and withdrawal code still uses provider book balances as if they were immediately recoverable. The Informational finding is resolved for the source-of-truth commit because the Arbitrum-specific providers are absent and the remaining Aave provider no longer uses the Arbitrum address from the report.

## Baseline

This response is based on the current repository state at `fd1c8747a01732448774ca3bfd6bc6cf2024b5fc` in `Thesauros/optimized-rebalancer-contracts` (`base-dev`). The PDF contains an internal reference to a different repository/commit (`Thesauros/contracts@93ca3de...`); this is treated as report metadata mismatch, not as the baseline for this response.

## Reviewed Evidence

- `contracts/Rebalancer.sol:409-439` withdraws from providers in fixed list order and subtracts the requested amount, not the actual amount received.
- `contracts/Rebalancer.sol:829-839` delegates provider actions and bubbles provider reverts.
- `contracts/Rebalancer.sol:845-855` computes `totalAssets()` from `provider.getDepositBalance()`.
- `contracts/providers/MorphoProvider.sol:120-126` reports MetaMorpho position value through `convertToAssets(shares)`.
- `contracts/providers/MorphoProvider.sol:131-159` uses MetaMorpho real market assets in the numerator and `totalAssets()` in the denominator.
- `contracts/interfaces/morpho/IMetaMorpho.sol:46-49` exposes `lostAssets()`.
- `contracts/providers/AaveV3Provider.sol:81-88` uses `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`, not the Arbitrum address from the report.
- `contracts/providers/DolomiteProvider.sol` and `contracts/providers/RevertProvider.sol` are deleted in the reviewed working tree.
- `deploy/deploy-usdc-vault.ts:25-26` and `utils/constants.ts:33` show the deployment script is oriented around Base chain id `8453`.

## THES2-1 - Fixed-order withdrawals may fail despite available liquidity

**Status:** Accepted, fix required  
**Severity:** Low  
**Current affected code:** `contracts/Rebalancer.sol:409-439`, `contracts/Rebalancer.sol:829-839`

### Response

The finding is valid. The current withdrawal loop uses each provider's `getDepositBalance()` as the amount that can be withdrawn immediately. That is an accounting value, not a liquidity guarantee.

If an earlier provider in `$._providers` reports a positive accounting balance but cannot satisfy the delegated `withdraw`, `_delegateActionToProvider()` bubbles the revert and the loop never reaches later providers. This can block a user withdrawal even when another provider later in the list holds enough liquid assets.

The revert is atomic, so the user shares are not permanently burned and vault accounting is restored. The impact is still real: the user cannot complete the withdrawal until liquidity returns, a provider list reorder is executed, or the code is upgraded.

### Remediation Plan

Implement withdrawal isolation and settle against actual received assets:

1. Replace the unconditional delegate call in the withdrawal path with an internal low-level delegatecall helper that returns success/failure without reverting the whole withdrawal loop.
2. For each provider attempt, measure the vault's underlying token balance before and after the provider call.
3. Reduce `assetsLeft` by the actual received amount, not by the requested provider amount.
4. Continue to the next provider when one provider fails or returns less than requested.
5. Revert only after all providers have been attempted and `assetsLeft` remains non-zero.
6. Add focused fork or mock tests where the first provider reports a positive balance but reverts on withdrawal, while the second provider has sufficient liquidity.

Pseudocode target:

```solidity
uint256 beforeBalance = asset.balanceOf(address(this));
bool success = _tryDelegateWithdraw(amount, provider);
if (!success) continue;

uint256 received = asset.balanceOf(address(this)) - beforeBalance;
if (received >= assetsLeft) {
    assetsLeft = 0;
} else {
    assetsLeft -= received;
}
```

### Risk Assessment

| Risk | Probability | Blast radius | Mitigation |
| --- | --- | --- | --- |
| User withdrawal temporarily blocked by an illiquid earlier provider | Low | User and protocol operations | Attempt all providers and settle by actual received assets |
| Provider reorder is needed during an incident | Medium | Operations team | Keep timelock/provider-management runbook ready until code fix ships |
| Fix introduces accounting mismatch | Medium | Vault accounting | Add tests for partial fills, failed providers, exact fills, and insufficient aggregate liquidity |

## THES2-3 - Persistent MetaMorpho `lostAssets` may misstate Rebalancer position value

**Status:** Accepted, fix required  
**Severity:** Low  
**Current affected code:** `contracts/providers/MorphoProvider.sol:120-159`, `contracts/Rebalancer.sol:152-153`, `contracts/Rebalancer.sol:845-855`

### Response

The finding is valid. The report path appears to contain a typo because the issue is in `MorphoProvider`, not `AaveV3Provider`.

`MorphoProvider.getDepositBalance()` currently uses MetaMorpho `convertToAssets(shares)`. For MetaMorpho V1.1, `lostAssets()` can persist after realized bad debt or forced market removal. If `totalAssets()` includes those missing assets, the Rebalancer can overstate the recoverable value of its MetaMorpho shares.

The inconsistency also exists in `getDepositRate()`: the numerator is based on current real supplied assets per Morpho market, while the denominator is `_metaMorpho.totalAssets()`. After a material `lostAssets` event, balance, rate, share conversion, fee calculation, and withdrawal logic may not use the same recoverable-value basis.

### Remediation Plan

Use one adjusted accounting basis for Morpho balances and rates:

1. Add a shared internal routine in `MorphoProvider` that computes adjusted MetaMorpho assets:
   - `bookTotalAssets = _metaMorpho.totalAssets()`
   - `lostAssets = _metaMorpho.lostAssets()`
   - `recoverableTotalAssets = bookTotalAssets > lostAssets ? bookTotalAssets - lostAssets : 0`
   - `recoverableUserAssets = shares * recoverableTotalAssets / _metaMorpho.totalSupply()`
2. Use the adjusted basis in `getDepositBalance()`.
3. Use the same adjusted denominator in `getDepositRate()`, with a zero-denominator guard.
4. Consider extending `IProvider` with an explicit withdrawable/recoverable-balance view so the Rebalancer does not treat accounting balances and liquid balances as the same value.
5. Add tests with a mock MetaMorpho vault where `lostAssets > 0` and verify:
   - `totalAssets()` is reduced by the Rebalancer's proportional lost-asset exposure.
   - `convertToAssets()` and fee accrual do not mint fees from unrecoverable assets.
   - withdrawals cannot overpay early redeemers at the expense of later shareholders.

### Risk Assessment

| Risk | Probability | Blast radius | Mitigation |
| --- | --- | --- | --- |
| MetaMorpho bad debt causes Rebalancer NAV overstatement | Low | All vault shareholders exposed to that provider | Use adjusted recoverable accounting |
| Early withdrawals after a loss shift more loss to later shareholders | Low | Remaining shareholders | Align share conversion, fees, and withdrawal calculations to adjusted assets |
| Rate display becomes inconsistent after loss | Low | Integrators and analytics | Use one accounting basis for both balance and rate |

## THES2-2 - Provider adapters hardcode Arbitrum protocol addresses

**Status:** Resolved for source-of-truth commit; hardening recommended  
**Severity:** Informational  
**Report-referenced code:** `AaveV3Provider.sol`, `DolomiteProvider.sol`, `RevertProvider.sol`

### Response

Against the source-of-truth commit `fd1c8747a01732448774ca3bfd6bc6cf2024b5fc`, the specific reported issue is resolved.

In the reviewed `optimized-rebalancer-contracts` tree:

- `DolomiteProvider.sol` is removed.
- `RevertProvider.sol` is removed.
- `AaveV3Provider` no longer uses the Arbitrum PoolAddressesProvider `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb`.
- `AaveV3Provider` now uses `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`, matching the current Base-oriented deployment target.
- Compound markets are configured through `ProviderManager`.
- Morpho vault addresses are constructor arguments in deployment.

That resolves the specific wrong-chain Arbitrum-address issue for the current Base deployment path.

The broader provider-hardening recommendation is still worth implementing as a follow-up. The code does not validate provider source bytecode or expected interface responses before approvals are granted and the provider list is stored. `Rebalancer._setProviders()` approves each provider source and then stores the list, but it does not validate all providers first and does not revoke allowances for removed provider sources.

### Remediation Plan

1. Make Aave's PoolAddressesProvider a constructor argument or configure it through `ProviderManager`, matching the Compound and Morpho pattern.
2. Add deployment-time chain guards so the Base deployment script fails fast when `chainId != 8453`.
3. Add provider registration checks before granting approvals:
   - provider address has code
   - source address has code
   - `getIdentifier()` returns an expected value
   - `getSource()` returns a non-zero contract address
   - provider-specific interface sanity calls do not revert
4. Validate the entire new provider list before writing storage.
5. Revoke approvals for provider sources that were removed from the active list.
6. Add tests for wrong-chain deployment constants, zero source addresses, non-contract sources, duplicate providers, and removed-provider allowance revocation.

### Risk Assessment

| Risk | Probability | Blast radius | Mitigation |
| --- | --- | --- | --- |
| Wrong-chain deployment uses a valid-looking but incorrect address | Low | Deployment and integrations | Constructor/config injection plus deploy chain guard |
| Provider source is invalid but receives token approval | Low | Vault assets if malicious provider is registered | Code/interface validation before approvals |
| Removed provider keeps allowance | Medium | Vault assets if old source becomes unsafe | Revoke removed-source allowances during provider updates |

## Final Position

THES2-1 and THES2-3 should remain open until code changes and tests are merged. THES2-2 can be marked resolved for the source-of-truth commit because the reported wrong-chain Arbitrum-address issue is not present there. Provider validation and allowance revocation should be tracked as separate hardening work.

No contract changes were made as part of this response document.
