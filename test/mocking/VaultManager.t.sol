// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {VaultManager} from "../../contracts/VaultManager.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract VaultManagerTests is MockingUtilities {
    uint256 public totalAssets;

    IProvider[] public sources;
    IProvider[] public destinations;

    function setUp() public {
        initializeVault(vault, MIN_AMOUNT, initializer);
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);
        executeDeposit(vault, DEPOSIT_AMOUNT, bob);

        totalAssets = 2 * DEPOSIT_AMOUNT + MIN_AMOUNT;

        sources.push(mockProviderA);
        destinations.push(mockProviderB);
    }

    // =========================================
    // rebalanceVault
    // =========================================

    function testRebalanceVaultRevertsIfCallerIsNotExecutor() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vm.expectRevert(
            AccessManager.AccessManager__CallerIsNotExecutor.selector
        );
        vm.prank(alice);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );
    }

    function testRebalanceVaultRevertsIfCountIsInvalid() public {
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(VaultManager.VaultManager__InvalidCount.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );
    }

    function testRebalanceVaultRevertsIfArraysMismatch() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        uint256[] memory invalidFees = new uint256[](0);

        vm.expectRevert(VaultManager.VaultManager__ArrayMismatch.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            invalidFees
        );

        IProvider[] memory invalidSources = new IProvider[](2);
        invalidSources[0] = mockProviderA;
        invalidSources[1] = mockProviderB;

        vm.expectRevert(VaultManager.VaultManager__ArrayMismatch.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            invalidSources,
            destinations,
            new uint256[](1)
        );

        IProvider[] memory invalidDestinations = new IProvider[](2);
        invalidDestinations[0] = mockProviderB;
        invalidDestinations[1] = mockProviderC;

        vm.expectRevert(VaultManager.VaultManager__ArrayMismatch.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            invalidDestinations,
            new uint256[](1)
        );
    }

    function testRebalanceVaultRevertsIfAssetAmountIsInvalid() public {
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(VaultManager.VaultManager__InvalidAssetAmount.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );

        amounts[0] = totalAssets + 1;

        vm.expectRevert(VaultManager.VaultManager__InvalidAssetAmount.selector);
        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );
    }

    function testRebalanceVaultIfMaxAssetsAreUsed() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );

        assertEq(getBalanceAtProvider(vault, mockProviderA), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderB), totalAssets);
    }

    function testRebalanceVault() public {
        uint256 assets = 2 * DEPOSIT_AMOUNT;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assets;

        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](1)
        );

        assertEq(getBalanceAtProvider(vault, mockProviderA), MIN_AMOUNT);
        assertEq(getBalanceAtProvider(vault, mockProviderB), assets);
    }
}
