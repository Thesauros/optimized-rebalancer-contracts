// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {AaveV3Provider} from "../../contracts/providers/AaveV3Provider.sol";
import {ForkingBase} from "./ForkingBase.t.sol";

contract AaveV3ProviderTests is ForkingBase {
    AaveV3Provider public aaveV3Provider;

    function setUp() public override {
        super.setUp();

        aaveV3Provider = new AaveV3Provider(AAVE_V3_POOL_ADDRESSES_PROVIDER);

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = aaveV3Provider;

        vault = _deployVault();
        _initializeVault(vault, usdc, providers);
    }

    // =========================================
    // deposit
    // =========================================

    function testDeposit() public {
        uint256 assets = THOUSAND;

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 previewed = vault.previewDeposit(assets);

        uint256 shares = _executeDeposit(vault, assets, alice);

        assertEq(shares, previewed);

        skip(10 seconds);
        vm.roll(block.number + 1);

        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.totalSupply(), initialTotalSupply + shares);
        assertGe(vault.convertToAssets(shares), assets);
    }

    // =========================================
    // withdraw
    // =========================================

    function testWithdraw() public {
        uint256 assets = THOUSAND;

        _executeDeposit(vault, assets, alice);

        skip(10 seconds);
        vm.roll(block.number + 1);

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 previewed = vault.previewWithdraw(assets);

        uint256 shares = _executeWithdraw(vault, assets, alice);

        assertEq(shares, previewed);
        assertEq(vault.totalSupply(), totalSupplyBefore - shares);
    }

    // =========================================
    // getDepositBalance
    // =========================================

    function testDepositBalance() public {
        uint256 assets = THOUSAND;

        _executeDeposit(vault, assets, alice);

        skip(10 seconds);
        vm.roll(block.number + 1);

        assertGe(vault.totalAssets(), initialTotalAssets + assets);
    }

    // =========================================
    // getDepositRate
    // =========================================

    function testDepositRate() public view {
        assertGt(aaveV3Provider.getDepositRate(vault), 0);
    }

    // =========================================
    // getIdentifier
    // =========================================

    function testIdentifier() public view {
        assertEq(aaveV3Provider.getIdentifier(), "Aave_V3_Provider");
    }
}
