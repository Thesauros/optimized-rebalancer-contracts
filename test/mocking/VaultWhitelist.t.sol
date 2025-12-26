// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {PausableActions} from "../../contracts/base/PausableActions.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";
import {AccessManager} from "../../contracts/access/AccessManager.sol";

contract VaultWhitelistTests is MockingUtilities {
    event WhitelistToggled(bool enabled);
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    function setUp() public {
        // Настраиваем timelock для vault
        vault.setTimelock(address(timelock));
        
        // Даем timelock ADMIN_ROLE для управления whitelist
        vault.grantRole(ADMIN_ROLE, address(timelock));
        
        // Размораживаем все действия (если они заморожены)
        try vault.unpause(PausableActions.Actions.Deposit) {} catch {}
        try vault.unpause(PausableActions.Actions.Withdraw) {} catch {}
    }

    // =========================================
    // toggleWhitelist
    // =========================================

    function testToggleWhitelistRevertsIfNotTimelock() public {
        vm.expectRevert(Vault.Vault__Unauthorized.selector);
        vm.prank(alice);
        vault.toggleWhitelist(true);
    }

    function testToggleWhitelistByTimelock() public {
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);
        
        assertTrue(vault.isWhitelistEnabled());
    }

    function testToggleWhitelistEmitsEvent() public {
        vm.expectEmit();
        emit WhitelistToggled(true);
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);
    }

    function testToggleWhitelistOff() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);
        assertTrue(vault.isWhitelistEnabled());

        // Выключаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(false);
        assertFalse(vault.isWhitelistEnabled());
    }

    // =========================================
    // addToWhitelist
    // =========================================

    function testAddToWhitelistRevertsIfNotTimelock() public {
        vm.expectRevert(Vault.Vault__Unauthorized.selector);
        vm.prank(alice);
        vault.addToWhitelist(bob);
    }

    function testAddToWhitelistRevertsIfZeroAddress() public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vm.prank(address(timelock));
        vault.addToWhitelist(address(0));
    }

    function testAddToWhitelist() public {
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
        
        assertTrue(vault.isWhitelisted(alice));
    }

    function testAddToWhitelistEmitsEvent() public {
        vm.expectEmit();
        emit RoleGranted(DEPOSITOR_ROLE, alice, address(timelock));
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
    }

    // =========================================
    // removeFromWhitelist
    // =========================================

    function testRemoveFromWhitelistRevertsIfNotTimelock() public {
        vm.expectRevert(Vault.Vault__Unauthorized.selector);
        vm.prank(alice);
        vault.removeFromWhitelist(bob);
    }

    function testRemoveFromWhitelistRevertsIfZeroAddress() public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vm.prank(address(timelock));
        vault.removeFromWhitelist(address(0));
    }

    function testRemoveFromWhitelist() public {
        // Добавляем в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
        assertTrue(vault.isWhitelisted(alice));

        // Удаляем из whitelist
        vm.prank(address(timelock));
        vault.removeFromWhitelist(alice);
        assertFalse(vault.isWhitelisted(alice));
    }

    function testRemoveFromWhitelistEmitsEvent() public {
        // Добавляем в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);

        // Удаляем из whitelist
        vm.expectEmit();
        emit RoleRevoked(DEPOSITOR_ROLE, alice, address(timelock));
        vm.prank(address(timelock));
        vault.removeFromWhitelist(alice);
    }

    // =========================================
    // isWhitelisted
    // =========================================

    function testIsWhitelistedReturnsFalseByDefault() public view {
        assertFalse(vault.isWhitelisted(alice));
    }

    function testIsWhitelistedReturnsTrueAfterAdding() public {
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
        
        assertTrue(vault.isWhitelisted(alice));
    }

    function testIsWhitelistedReturnsFalseAfterRemoving() public {
        // Добавляем
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
        assertTrue(vault.isWhitelisted(alice));

        // Удаляем
        vm.prank(address(timelock));
        vault.removeFromWhitelist(alice);
        assertFalse(vault.isWhitelisted(alice));
    }

    // =========================================
    // isWhitelistEnabled
    // =========================================

    function testIsWhitelistEnabledReturnsFalseByDefault() public view {
        assertFalse(vault.isWhitelistEnabled());
    }

    function testIsWhitelistEnabledReturnsTrueAfterEnabling() public {
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);
        
        assertTrue(vault.isWhitelistEnabled());
    }

    function testIsWhitelistEnabledReturnsFalseAfterDisabling() public {
        // Включаем
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);
        assertTrue(vault.isWhitelistEnabled());

        // Выключаем
        vm.prank(address(timelock));
        vault.toggleWhitelist(false);
        assertFalse(vault.isWhitelistEnabled());
    }

    // =========================================
    // Deposit with whitelist
    // =========================================

    function testDepositSucceedsWhenWhitelistDisabled() public {
        // Whitelist выключен по умолчанию
        assertFalse(vault.isWhitelistEnabled());

        // Alice не в whitelist, но может депозитить
        assertFalse(vault.isWhitelisted(alice));
        
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        
        assertEq(vault.balanceOf(alice), depositAmount);
    }

    function testDepositSucceedsWhenWhitelistEnabledAndUserWhitelisted() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Добавляем Alice в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);

        // Alice может депозитить
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        
        assertEq(vault.balanceOf(alice), depositAmount);
    }

    function testDepositRevertsWhenWhitelistEnabledAndUserNotWhitelisted() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice не в whitelist
        assertFalse(vault.isWhitelisted(alice));

        // Alice не может депозитить
        uint256 depositAmount = 1000 ether;
        asset.mint(alice, depositAmount);

        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(Vault.Vault__NotWhitelisted.selector);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    function testDepositSucceedsAfterAddingToWhitelist() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice не может депозитить
        uint256 depositAmount = 1000 ether;
        asset.mint(alice, depositAmount);

        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(Vault.Vault__NotWhitelisted.selector);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Добавляем Alice в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);

        // Теперь Alice может депозитить
        executeDeposit(vault, depositAmount, alice);
        assertEq(vault.balanceOf(alice), depositAmount);
    }

    function testDepositRevertsAfterRemovingFromWhitelist() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Добавляем Alice в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);

        // Alice может депозитить
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        assertEq(vault.balanceOf(alice), depositAmount);

        // Удаляем Alice из whitelist
        vm.prank(address(timelock));
        vault.removeFromWhitelist(alice);

        // Alice больше не может депозитить
        asset.mint(alice, depositAmount);
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(Vault.Vault__NotWhitelisted.selector);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    // =========================================
    // Mint with whitelist
    // =========================================

    function testMintSucceedsWhenWhitelistDisabled() public {
        // Whitelist выключен по умолчанию
        assertFalse(vault.isWhitelistEnabled());

        // Alice не в whitelist, но может минтить
        assertFalse(vault.isWhitelisted(alice));
        
        uint256 mintAmount = 1000 ether;
        executeMint(vault, mintAmount, alice);
        
        assertEq(vault.balanceOf(alice), mintAmount);
    }

    function testMintSucceedsWhenWhitelistEnabledAndUserWhitelisted() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Добавляем Alice в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);

        // Alice может минтить
        uint256 mintAmount = 1000 ether;
        executeMint(vault, mintAmount, alice);
        
        assertEq(vault.balanceOf(alice), mintAmount);
    }

    function testMintRevertsWhenWhitelistEnabledAndUserNotWhitelisted() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice не в whitelist
        assertFalse(vault.isWhitelisted(alice));

        // Alice не может минтить
        uint256 mintAmount = 1000 ether;
        asset.mint(alice, mintAmount);

        vm.startPrank(alice);
        asset.approve(address(vault), mintAmount);
        vm.expectRevert(Vault.Vault__NotWhitelisted.selector);
        vault.mint(mintAmount, alice);
        vm.stopPrank();
    }

    // =========================================
    // Withdraw and Redeem (should not be affected by whitelist)
    // =========================================

    function testWithdrawNotAffectedByWhitelist() public {
        // Сначала делаем депозит
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice может выводить средства даже если whitelist включен
        uint256 withdrawAmount = 500 ether;
        executeWithdraw(vault, withdrawAmount, alice);
        
        assertEq(vault.balanceOf(alice), depositAmount - withdrawAmount);
    }

    function testRedeemNotAffectedByWhitelist() public {
        // Сначала делаем депозит
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice может редимить даже если whitelist включен
        uint256 redeemAmount = 500 ether;
        executeRedeem(vault, redeemAmount, alice);
        
        assertEq(vault.balanceOf(alice), depositAmount - redeemAmount);
    }

    // =========================================
    // Edge cases
    // =========================================

    function testMultipleUsersWhitelist() public {
        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Добавляем Alice и Bob в whitelist
        vm.prank(address(timelock));
        vault.addToWhitelist(alice);
        
        vm.prank(address(timelock));
        vault.addToWhitelist(bob);

        // Оба могут депозитить
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        executeDeposit(vault, depositAmount, bob);
        
        assertEq(vault.balanceOf(alice), depositAmount);
        assertEq(vault.balanceOf(bob), depositAmount);
    }

    function testWhitelistToggleDuringDeposit() public {
        // Alice делает депозит когда whitelist выключен
        uint256 depositAmount = 1000 ether;
        executeDeposit(vault, depositAmount, alice);
        assertEq(vault.balanceOf(alice), depositAmount);

        // Включаем whitelist
        vm.prank(address(timelock));
        vault.toggleWhitelist(true);

        // Alice не может делать новые депозиты
        asset.mint(alice, depositAmount);
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(Vault.Vault__NotWhitelisted.selector);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Но может выводить существующие средства
        executeWithdraw(vault, 500 ether, alice);
        assertEq(vault.balanceOf(alice), depositAmount - 500 ether);
    }
}
