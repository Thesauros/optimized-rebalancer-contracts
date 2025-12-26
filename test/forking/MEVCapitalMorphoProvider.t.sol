// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {MorphoProvider} from "../../contracts/providers/MorphoProvider.sol";
import {ForkingUtilities} from "../utils/ForkingUtilities.sol";

contract MEVCapitalMorphoProviderTests is ForkingUtilities {
    MorphoProvider public morphoProvider;

    function setUp() public {
        morphoProvider = new MorphoProvider(MORPHO_MEV_CAPITAL_VAULT_ADDRESS);

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

        uint256 mintedSharesAfter = vault.balanceOf(alice);
        uint256 assetBalanceAfter = vault.convertToAssets(mintedSharesAfter);

        assertGt(mintedSharesAfter, mintedSharesBefore);
        assertGt(assetBalanceAfter, assetBalanceBefore);
    }

    // =========================================
    // withdraw
    // =========================================

    function testWithdraw() public {
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        uint256 mintedSharesBefore = vault.balanceOf(alice);
        uint256 assetBalanceBefore = vault.convertToAssets(mintedSharesBefore);

        executeWithdraw(vault, assetBalanceBefore, alice);

        uint256 mintedSharesAfter = vault.balanceOf(alice);
        uint256 assetBalanceAfter = vault.convertToAssets(mintedSharesAfter);

        assertLt(mintedSharesAfter, mintedSharesBefore);
        assertLt(assetBalanceAfter, assetBalanceBefore);
    }

    // =========================================
    // getDepositBalance
    // =========================================

    function testDepositBalance() public {
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        uint256 depositBalance = morphoProvider.getDepositBalance(alice, vault);

        assertGe(depositBalance, 0);
    }

    // =========================================
    // getDepositRate
    // =========================================

    function testDepositRate() public view {
        uint256 rate = morphoProvider.getDepositRate(vault);

        assertGt(rate, 0);
    }

    // =========================================
    // getIdentifier
    // =========================================

    function testIdentifier() public view {
        string memory identifier = morphoProvider.getIdentifier();

        assertEq(identifier, "Morpho_Provider");
    }
}
