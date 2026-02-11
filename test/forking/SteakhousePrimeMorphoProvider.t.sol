// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {MorphoProvider} from "../../contracts/providers/MorphoProvider.sol";
import {ForkingBase} from "./ForkingBase.t.sol";

contract SteakhousePrimeMorphoProviderTests is ForkingBase {
    MorphoProvider public morphoProvider;

    function setUp() public override {
        super.setUp();

        morphoProvider = new MorphoProvider(
            MORPHO_STEAKHOUSE_PRIME_VAULT_ADDRESS
        );

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = morphoProvider;

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
        assertGt(morphoProvider.getDepositRate(vault), 0);
    }

    // =========================================
    // getIdentifier
    // =========================================

    function testIdentifier() public view {
        assertEq(morphoProvider.getIdentifier(), "Morpho_Provider");
    }
}
