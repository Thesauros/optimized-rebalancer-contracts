// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {PausableActions} from "../../contracts/base/PausableActions.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract PausableActionsTests is MockingUtilities {
    event Paused(address account, PausableActions.Actions action);
    event Unpaused(address account, PausableActions.Actions action);

    function setUp() public {
        initializeVault(vault, MIN_AMOUNT, initializer);
    }

    // =========================================
    // pause
    // =========================================

    function testPauseRevertsIfCallerIsNotAdmin() public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.pause(PausableActions.Actions.Deposit);
    }

    function testPauseRevertsIfAlreadyPaused() public {
        vault.pause(PausableActions.Actions.Deposit);

        vm.expectRevert(PausableActions.PausableActions__ActionPaused.selector);
        vault.pause(PausableActions.Actions.Deposit);
    }

    function testDepositRevertsIfPaused() public {
        vault.pause(PausableActions.Actions.Deposit);

        vm.expectRevert(PausableActions.PausableActions__ActionPaused.selector);
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    function testWithdrawRevertsIfPaused() public {
        vault.pause(PausableActions.Actions.Withdraw);
        executeDeposit(vault, DEPOSIT_AMOUNT, alice);

        vm.expectRevert(PausableActions.PausableActions__ActionPaused.selector);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);
    }

    function testPause() public {
        vault.pause(PausableActions.Actions.Deposit);
        assertTrue(vault.paused(PausableActions.Actions.Deposit));

        vault.pause(PausableActions.Actions.Withdraw);
        assertTrue(vault.paused(PausableActions.Actions.Withdraw));
    }

    function testPauseEmitsEvent() public {
        vm.expectEmit();
        emit Paused(address(this), PausableActions.Actions.Deposit);
        vault.pause(PausableActions.Actions.Deposit);

        vm.expectEmit();
        emit Paused(address(this), PausableActions.Actions.Withdraw);
        vault.pause(PausableActions.Actions.Withdraw);
    }

    // =========================================
    // unpause
    // =========================================

    function testUnpauseRevertsIfCallerIsNotAdmin() public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.unpause(PausableActions.Actions.Deposit);
    }

    function testUnpauseRevertsIfNotPaused() public {
        vm.expectRevert(
            PausableActions.PausableActions__ActionNotPaused.selector
        );
        vault.unpause(PausableActions.Actions.Deposit);
    }

    function testUnpause() public {
        vault.pause(PausableActions.Actions.Deposit);
        vault.pause(PausableActions.Actions.Withdraw);

        vault.unpause(PausableActions.Actions.Deposit);
        assertFalse(vault.paused(PausableActions.Actions.Deposit));

        vault.unpause(PausableActions.Actions.Withdraw);
        assertFalse(vault.paused(PausableActions.Actions.Withdraw));
    }

    function testUnpauseEmitsEvent() public {
        vault.pause(PausableActions.Actions.Deposit);
        vault.pause(PausableActions.Actions.Withdraw);

        vm.expectEmit();
        emit Unpaused(address(this), PausableActions.Actions.Deposit);
        vault.unpause(PausableActions.Actions.Deposit);

        vm.expectEmit();
        emit Unpaused(address(this), PausableActions.Actions.Withdraw);
        vault.unpause(PausableActions.Actions.Withdraw);
    }
}
