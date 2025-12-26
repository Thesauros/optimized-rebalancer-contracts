// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract AccessManagerTests is MockingUtilities {
    AccessManager public accessManager;

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
        accessManager = new AccessManager();
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructor() public view {
        assertTrue(accessManager.hasRole(ADMIN_ROLE, address(this)));
    }

    // =========================================
    // grantRole
    // =========================================

    function testGrantRoleRevertsIfCallerIsNotAdmin() public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        accessManager.grantRole(ADMIN_ROLE, alice);
    }

    function testGrantRole() public {
        accessManager.grantRole(EXECUTOR_ROLE, alice);
        assertTrue(accessManager.hasRole(EXECUTOR_ROLE, alice));
    }

    function testGrantRoleEmitsEvent() public {
        vm.expectEmit();
        emit RoleGranted(EXECUTOR_ROLE, alice, address(this));
        accessManager.grantRole(EXECUTOR_ROLE, alice);
    }

    // =========================================
    // revokeRole
    // =========================================

    function testRevokeRoleRevertsIfCallerIsNotAdmin() public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        accessManager.revokeRole(ADMIN_ROLE, alice);
    }

    function testRevokeRole() public {
        accessManager.grantRole(EXECUTOR_ROLE, alice);
        accessManager.revokeRole(EXECUTOR_ROLE, alice);
        assertFalse(accessManager.hasRole(EXECUTOR_ROLE, alice));
    }

    function testRevokeRoleEmitsEvent() public {
        accessManager.grantRole(EXECUTOR_ROLE, alice);
        vm.expectEmit();
        emit RoleRevoked(EXECUTOR_ROLE, alice, address(this));
        accessManager.revokeRole(EXECUTOR_ROLE, alice);
    }
}
