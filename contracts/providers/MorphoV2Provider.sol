// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, Id, Market, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {IMetaMorpho} from "../interfaces/morpho/IMetaMorpho.sol";
import {
    IMorphoVaultV2,
    IMorphoV2Adapter,
    IMorphoVaultV1Adapter,
    IMorphoMarketV1AdapterV2
} from "../interfaces/morpho/IMorphoVaultV2.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";

/// @notice Morpho Vault V2 provider, including Gauntlet's V2 vaults.
/// @dev Actions are delegatecalled by Rebalancer. Configuration MUST stay immutable.
///      Native V2 max* views return zero; they are deliberately never used here.
contract MorphoV2Provider is IProvider {
    using MorphoBalancesLib for IMorpho;

    uint256 private constant WAD = 1e18;
    uint256 private constant WAD_TO_RAY = 1e9;
    uint256 private constant YEAR = 365 days;
    uint256 private constant ADAPTER_RATE_CALL_GAS = 3_000_000;

    IMorphoVaultV2 public immutable morphoVault;
    address private immutable _asset;

    error InvalidMorphoVault();
    error InvalidVaultContext();
    error AssetMismatch();

    constructor(address morphoVault_) {
        if (morphoVault_.code.length == 0) revert InvalidMorphoVault();
        morphoVault = IMorphoVaultV2(morphoVault_);
        _asset = morphoVault.asset();
        if (_asset.code.length == 0) revert InvalidMorphoVault();
        // Reject V1/generic ERC4626 sources at deployment, before any approvals.
        morphoVault.accrueInterestView();
        morphoVault.adaptersLength();
    }

    function deposit(uint256 amount, IRebalancer vault) external override returns (bool) {
        _checkVault(vault);
        morphoVault.deposit(amount, address(vault));
        return true;
    }

    /// @dev Insufficient liquidity, caps and gates revert natively. Never force
    ///      deallocate: that can burn shares as a penalty without user consent.
    function withdraw(uint256 amount, IRebalancer vault) external override returns (bool) {
        _checkVault(vault);
        morphoVault.withdraw(amount, address(vault), address(vault));
        return true;
    }

    function _checkVault(IRebalancer vault) private view {
        if (address(this) != address(vault)) revert InvalidVaultContext();
        if (vault.asset() != _asset) revert AssetMismatch();
    }

    /// @notice Full position value, irrespective of immediately available liquidity.
    /// @dev V2 previews include pending performance/management fee shares, virtual
    ///      assets/shares, maxRate-limited accrual and recognized losses.
    function getDepositBalance(address user, IRebalancer) external view override returns (uint256) {
        uint256 shares = morphoVault.balanceOf(user);
        return shares == 0 ? 0 : morphoVault.previewRedeem(shares);
    }

    /// @notice Estimated net supply APR in ray (1e27), excluding external rewards.
    /// @dev Covers MorphoVaultV1Adapter and MorphoMarketV1AdapterV2. Unknown adapter
    ///      yield is zero; its assets and idle cash still dilute the portfolio APR.
    ///      maxRate is an accrual ceiling, never a substitute for actual yield.
    function getDepositRate(IRebalancer) external view override returns (uint256 rate) {
        uint256 count = morphoVault.adaptersLength();
        uint256 assets = morphoVault.totalAssets();
        if (assets == 0) return 0;
        uint256 rateCap = uint256(morphoVault.maxRate()) * YEAR * WAD_TO_RAY;

        for (uint256 i; i < count; ++i) {
            address adapter = morphoVault.adapters(i);
            // An external boundary catches failures anywhere in the contribution,
            // including decoding and code in the inner try's success body.
            try this.getAdapterRateContribution{gas: ADAPTER_RATE_CALL_GAS}(adapter, assets) returns (
                uint256 contribution
            ) {
                // Saturate before adding so extreme rates cannot overflow the sum.
                rate += Math.min(contribution, rateCap - rate);
            } catch {}
        }

        rate = Math.mulDiv(rate, WAD - morphoVault.performanceFee(), WAD);
        uint256 managementRate = uint256(morphoVault.managementFee()) * YEAR * WAD_TO_RAY;
        rate = rate > managementRate ? rate - managementRate : 0;
    }

    /// @notice Weighted adapter APR contribution in ray, before the V2 vault's fees.
    /// @dev External boundary for getDepositRate's bounded try/catch. Direct calls
    ///      may revert for unsupported adapters or an invalid total-assets input.
    function getAdapterRateContribution(address adapter, uint256 totalAssets) external view returns (uint256) {
        uint256 assets = IMorphoV2Adapter(adapter).realAssets();
        return assets == 0 ? 0 : Math.mulDiv(_adapterRate(adapter), assets, totalAssets);
    }

    function _adapterRate(address adapter) private view returns (uint256) {
        // Both interfaces are probed explicitly; unrelated adapters contribute 0.
        try IMorphoVaultV1Adapter(adapter).morphoVaultV1() returns (address underlying) {
            return _vaultV1Rate(IMetaMorpho(underlying));
        } catch {}
        try IMorphoMarketV1AdapterV2(adapter).morpho() returns (address morpho) {
            return _marketAdapterRate(IMorphoMarketV1AdapterV2(adapter), IMorpho(morpho));
        } catch {}
        return 0;
    }

    function _vaultV1Rate(IMetaMorpho underlying) private view returns (uint256 rate) {
        IMorpho morpho = underlying.MORPHO();
        uint256 assets = underlying.totalAssets();
        if (assets == 0) return 0;
        uint256 count = underlying.withdrawQueueLength();
        for (uint256 i; i < count; ++i) {
            Id id = underlying.withdrawQueue(i);
            MarketParams memory params = morpho.idToMarketParams(id);
            uint256 supplied = morpho.expectedSupplyAssets(params, address(underlying));
            if (supplied == 0) continue;
            rate += Math.mulDiv(_marketRate(morpho, id, params), supplied, assets);
        }
        return Math.mulDiv(rate, WAD - underlying.fee(), WAD);
    }

    function _marketAdapterRate(IMorphoMarketV1AdapterV2 adapter, IMorpho morpho) private view returns (uint256 rate) {
        uint256 assets = adapter.realAssets();
        if (assets == 0) return 0;
        uint256 count = adapter.marketIdsLength();
        for (uint256 i; i < count; ++i) {
            bytes32 marketId = adapter.marketIds(i);
            uint256 supplied = adapter.expectedSupplyAssets(marketId);
            if (supplied == 0) continue;
            Id id = Id.wrap(marketId);
            rate += Math.mulDiv(_marketRate(morpho, id, morpho.idToMarketParams(id)), supplied, assets);
        }
    }

    function _marketRate(IMorpho morpho, Id id, MarketParams memory params) private view returns (uint256) {
        if (params.irm == address(0)) return 0;
        (uint256 supplyAssets,, uint256 borrowAssets,) = morpho.expectedMarketBalances(params);
        if (supplyAssets == 0 || borrowAssets == 0) return 0;
        Market memory market = morpho.market(id);
        uint256 borrowApr = IIrm(params.irm).borrowRateView(params, market) * YEAR * WAD_TO_RAY;
        uint256 supplyApr = Math.mulDiv(borrowApr, Math.min(borrowAssets, supplyAssets), supplyAssets);
        return Math.mulDiv(supplyApr, WAD - market.fee, WAD);
    }

    function getSource(address, address, address) external view override returns (address) {
        return address(morphoVault);
    }

    function getIdentifier() external pure override returns (string memory) {
        return "Morpho_V2_Provider";
    }
}
