// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {MorphoProvider} from "../../contracts/providers/MorphoProvider.sol";
import {ForkingUtilities} from "../utils/ForkingUtilities.sol";

contract GauntletPrimeMorphoProviderTests is ForkingUtilities {
    MorphoProvider public morphoProvider;

    function setUp() public {
        morphoProvider = new MorphoProvider(
            MORPHO_GAUNTLET_PRIME_VAULT_ADDRESS
        );

        IProvider[] memory providers = new IProvider[](1);
        providers[0] = morphoProvider;

        deployVault(address(usdc), providers);
        initializeVault(vault, MIN_AMOUNT, initializer);
    }

    // =========================================
    // deposit
    // =========================================

    function testDeposit() public {
        uint256 mintedSharesBefore = vault.balanceOf(alice);
        uint256 assetBalanceBefore = vault.convertToAssets(mintedSharesBefore);

        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        vm.warp(block.timestamp + 10 seconds);
        vm.roll(block.number + 1);

        uint256 mintedShares = vault.balanceOf(alice);
        uint256 assetBalance = vault.convertToAssets(mintedShares);

        assertGe(assetBalance - assetBalanceBefore, DEPOSIT_AMOUNT);
    }

    // =========================================
    // withdraw
    // =========================================

    function testWithdraw() public {
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        vm.warp(block.timestamp + 10 seconds);
        vm.roll(block.number + 1);

        address asset = vault.asset();

        uint256 balanceBefore = IERC20(asset).balanceOf(alice);
        uint256 maxWithdrawable = vault.maxWithdraw(alice);
        uint256 fee = (maxWithdrawable * WITHDRAW_FEE_PERCENT) /
            PRECISION_FACTOR;

        executeWithdraw(vault, maxWithdrawable, alice);

        uint256 balanceAfter = balanceBefore + maxWithdrawable - fee;

        assertEq(IERC20(asset).balanceOf(alice), balanceAfter);
    }

    // =========================================
    // getDepositBalance
    // =========================================

    function testDepositBalance() public {
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        vm.warp(block.timestamp + 10 seconds);
        vm.roll(block.number + 1);

        assertGe(vault.totalAssets(), DEPOSIT_AMOUNT + MIN_AMOUNT);
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
