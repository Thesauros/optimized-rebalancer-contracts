// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {ProviderManager} from "../../contracts/utils/ProviderManager.sol";
import {CompoundV3Provider} from "../../contracts/providers/CompoundV3Provider.sol";
import {ForkingBase} from "./ForkingBase.t.sol";

contract CompoundV3ProviderTests is ForkingBase {
    ProviderManager public providerManager;
    CompoundV3Provider public compoundV3Provider;

    function setUp() public override {
        super.setUp();

        providerManager = new ProviderManager(address(this));
        providerManager.setYieldToken(
            "Compound_V3_Provider",
            USDC_ADDRESS,
            COMET_USDC_ADDRESS
        );

        compoundV3Provider = new CompoundV3Provider(address(providerManager));

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = compoundV3Provider;

        vault = _deployVault();
        _initializeVault(vault, usdc, providers);
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructorRevertsIfProviderManagerIsAddressZero() public {
        vm.expectRevert(
            CompoundV3Provider.CompoundV3Provider__AddressZero.selector
        );
        new CompoundV3Provider(address(0));
    }

    function testConstructor() public view {
        assertEq(
            address(compoundV3Provider.getProviderManager()),
            address(providerManager)
        );
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
        assertGt(compoundV3Provider.getDepositRate(vault), 0);
    }

    // =========================================
    // getIdentifier
    // =========================================

    function testIdentifier() public view {
        assertEq(compoundV3Provider.getIdentifier(), "Compound_V3_Provider");
    }
}
