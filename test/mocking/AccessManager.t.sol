// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract AccessManagerTests is MockingBase {
    
    // =========================================
    // grantRole
    // =========================================

    function testGrantRoleRevertsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.grantRole(ADMIN_ROLE, alice);
    }

    function testGrantRole() public {
        vault.grantRole(EXECUTOR_ROLE, alice);
        assertTrue(vault.hasRole(EXECUTOR_ROLE, alice));
    }

    function testGrantRoleEmitsEvent() public {
        vm.expectEmit(address(vault));
        emit IAccessManager.RoleGranted(EXECUTOR_ROLE, alice, address(this));
        vault.grantRole(EXECUTOR_ROLE, alice);
    }

    // =========================================
    // revokeRole
    // =========================================

    function testRevokeRoleRevertsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.revokeRole(ADMIN_ROLE, alice);
    }

    function testRevokeRole() public {
        vault.grantRole(EXECUTOR_ROLE, alice);
        vault.revokeRole(EXECUTOR_ROLE, alice);
        assertFalse(vault.hasRole(EXECUTOR_ROLE, alice));
    }

    function testRevokeRoleEmitsEvent() public {
        vault.grantRole(EXECUTOR_ROLE, alice);
        vm.expectEmit(address(vault));
        emit IAccessManager.RoleRevoked(EXECUTOR_ROLE, alice, address(this));
        vault.revokeRole(EXECUTOR_ROLE, alice);
    }
}
