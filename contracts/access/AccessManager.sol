// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IAccessManager} from "../interfaces/IAccessManager.sol";

/**
 * @title AccessManager
 *
 * @dev Inspired and modified from OpenZeppelin's AccessControl contract.
 */
abstract contract AccessManager is ContextUpgradeable, IAccessManager {
    bytes32 public constant ADMIN_ROLE = 0x00;
    // note: rebalancer usage, if roles become vault-specific, consider moving to constants or roles.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @custom:storage-location erc7201:thesauros.storage.AccessManager
    struct AccessManagerStorage {
        mapping(bytes32 role => mapping(address account => bool)) _roles;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.AccessManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessManagerStorageLocation =
        0x269ca335d49f0b8bbf3a5a2cc9876243b5841edd3dfc837ebccdab385b0bb300;

    function _getAccessManagerStorage()
        private
        pure
        returns (AccessManagerStorage storage $)
    {
        assembly {
            $.slot := AccessManagerStorageLocation
        }
    }

    /// @dev Modifier that checks that an account has a specific role.
    modifier onlyRole(bytes32 role) {
        _onlyRole(role);
        _;
    }

    /// @dev Sets the initial admin during initialization.
    function __AccessManager_init(address admin_) internal onlyInitializing {
        __AccessManager_init_unchained(admin_);
    }

    function __AccessManager_init_unchained(address admin_) internal onlyInitializing {
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @dev Grants a role to an account.
    function grantRole(
        bytes32 role,
        address account
    ) public virtual onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @dev Revokes a role from an account.
    function revokeRole(
        bytes32 role,
        address account
    ) public virtual onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @dev Internal function to grant a role if not already set.
    function _grantRole(bytes32 role, address account) internal {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        if (!hasRole(role, account)) {
            $._roles[role][account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    /// @dev Internal function to revoke a role if set.
    function _revokeRole(bytes32 role, address account) internal {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        if (hasRole(role, account)) {
            $._roles[role][account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }

    function _onlyRole(bytes32 role) internal view {
        if (!hasRole(role, _msgSender())) {
            revert Unauthorized();
        }
    }

    /// @dev Returns true if an account has been granted role.
    function hasRole(
        bytes32 role,
        address account
    ) public view virtual returns (bool) {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        return $._roles[role][account];
    }
}
