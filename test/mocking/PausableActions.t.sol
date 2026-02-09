// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IPausableActions} from "../../contracts/interfaces/IPausableActions.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract PausableActionsTests is MockingBase {
    
    // =========================================
    // pause
    // =========================================

    function testPauseRevertsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.pause(IPausableActions.Actions.Deposit);
    }

    function testPauseRevertsIfAlreadyPaused() public {
        vault.pause(IPausableActions.Actions.Deposit);

        vm.expectRevert(IPausableActions.ActionPaused.selector);
        vault.pause(IPausableActions.Actions.Deposit);
    }

    function testDepositRevertsIfPaused() public {
        vault.pause(IPausableActions.Actions.Deposit);

        vm.prank(alice);
        vm.expectRevert(IPausableActions.ActionPaused.selector);
        vault.deposit(HUNDRED, alice);
    }

    function testWithdrawRevertsIfPaused() public {
        vault.pause(IPausableActions.Actions.Withdraw);
        _executeDeposit(vault, HUNDRED, alice);

        vm.prank(alice);
        vm.expectRevert(IPausableActions.ActionPaused.selector);
        vault.withdraw(HUNDRED, alice, alice);
    }

    function testPause() public {
        vault.pause(IPausableActions.Actions.Deposit);
        assertTrue(vault.paused(IPausableActions.Actions.Deposit));

        vault.pause(IPausableActions.Actions.Withdraw);
        assertTrue(vault.paused(IPausableActions.Actions.Withdraw));
    }

    function testPauseEmitsEvents() public {
        vm.expectEmit(address(vault));
        emit IPausableActions.Paused(
            address(this),
            IPausableActions.Actions.Deposit
        );
        vault.pause(IPausableActions.Actions.Deposit);

        vm.expectEmit(address(vault));
        emit IPausableActions.Paused(
            address(this),
            IPausableActions.Actions.Withdraw
        );
        vault.pause(IPausableActions.Actions.Withdraw);
    }

    // =========================================
    // unpause
    // =========================================

    function testUnpauseRevertsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.unpause(IPausableActions.Actions.Deposit);
    }

    function testUnpauseRevertsIfNotPaused() public {
        vm.expectRevert(IPausableActions.ActionNotPaused.selector);
        vault.unpause(IPausableActions.Actions.Deposit);
    }

    function testUnpause() public {
        vault.pause(IPausableActions.Actions.Deposit);
        vault.pause(IPausableActions.Actions.Withdraw);

        vault.unpause(IPausableActions.Actions.Deposit);
        assertFalse(vault.paused(IPausableActions.Actions.Deposit));

        vault.unpause(IPausableActions.Actions.Withdraw);
        assertFalse(vault.paused(IPausableActions.Actions.Withdraw));
    }

    function testUnpauseEmitsEvents() public {
        vault.pause(IPausableActions.Actions.Deposit);
        vault.pause(IPausableActions.Actions.Withdraw);

        vm.expectEmit(address(vault));
        emit IPausableActions.Unpaused(
            address(this),
            IPausableActions.Actions.Deposit
        );
        vault.unpause(IPausableActions.Actions.Deposit);

        vm.expectEmit(address(vault));
        emit IPausableActions.Unpaused(
            address(this),
            IPausableActions.Actions.Withdraw
        );
        vault.unpause(IPausableActions.Actions.Withdraw);
    }
}
