// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {PausableActions} from "../../contracts/base/PausableActions.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract RebalancerSetupTests is MockingUtilities {
    event SetupCompleted(address indexed setupAddress);

    // =========================================
    // constructor
    // =========================================

    function testConstructorRevertsIfAssetIsInvalid() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderA;

        vm.expectRevert(Vault.Vault__AddressZero.selector);
        new Rebalancer(
            address(0),
            "Rebalance tUSDT",
            "rtUSDT",
            providers,
            WITHDRAW_FEE_PERCENT,
            address(timelock),
            treasury
        );
    }

    function testConstructor() public view {
        assertEq(vault.asset(), address(asset));
        assertEq(vault.decimals(), ASSET_DECIMALS);
        assertEq(vault.name(), "Rebalance tUSDT");
        assertEq(vault.symbol(), "rtUSDT");
        assertEq(vault.timelock(), address(this));
        assertEq(address(vault.getProviders()[0]), address(mockProviderA));
        assertEq(address(vault.getProviders()[1]), address(mockProviderB));
        assertEq(address(vault.activeProvider()), address(mockProviderA));
        assertEq(vault.minAmount(), MIN_AMOUNT);
        assertEq(vault.withdrawFeePercent(), WITHDRAW_FEE_PERCENT);
        assertEq(vault.treasury(), treasury);
        assertTrue(vault.paused(PausableActions.Actions.Deposit));
    }

    // =========================================
    // setupVault
    // =========================================

    function testSetupVaultRevertsifAlreadyCompleted() public {
        initializeVault(vault, MIN_AMOUNT, initializer);

        vm.expectRevert(Vault.Vault__SetupAlreadyCompleted.selector);
        vault.setupVault(MIN_AMOUNT);
    }

    function testSetupVaultRevertsIfAmountBelowMin() public {
        uint256 assets = MIN_AMOUNT - 1;

        vm.expectRevert(Vault.Vault__DepositLessThanMin.selector);
        vault.setupVault(assets);
    }

    function testSetupVault() public {
        initializeVault(vault, MIN_AMOUNT, initializer);

        uint256 shares = vault.balanceOf(address(vault));

        assertTrue(vault.setupCompleted());
        assertFalse(vault.paused(PausableActions.Actions.Deposit));
        assertEq(vault.totalAssets(), MIN_AMOUNT);
        assertEq(shares, MIN_AMOUNT);
    }

    function testSetupVaultEmitsEvent() public {
        uint256 assets = MIN_AMOUNT;
        asset.mint(initializer, assets);

        vm.startPrank(initializer);
        asset.approve(address(vault), assets);

        vm.expectEmit();
        emit SetupCompleted(initializer);
        vault.setupVault(assets);
    }
}
