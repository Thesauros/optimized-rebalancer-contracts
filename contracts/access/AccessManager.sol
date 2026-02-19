// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IAccessManager} from "../interfaces/IAccessManager.sol";

/// @title AccessManager
/// @notice Allows role-based access management.
/// @dev Inspired and modified from OpenZeppelin's AccessControl contract.
abstract contract AccessManager is ContextUpgradeable, IAccessManager {
    /// @notice Admin role identifier.
    bytes32 public constant ADMIN_ROLE = 0x00;

    /// @notice Executor role identifier.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // may become vault-specific

    /// @custom:storage-location erc7201:thesauros.storage.AccessManager
    struct AccessManagerStorage {
        mapping(bytes32 role => mapping(address account => bool)) _roles;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.AccessManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessManagerStorageLocation =
        0x269ca335d49f0b8bbf3a5a2cc9876243b5841edd3dfc837ebccdab385b0bb300;

    /// @dev Returns the ERC-7201 namespaced storage pointer.
    function _getAccessManagerStorage()
        private
        pure
        returns (AccessManagerStorage storage $)
    {
        assembly {
            $.slot := AccessManagerStorageLocation
        }
    }

    /// @dev Checks that the caller has the specified role.
    /// @param role The role required for the call.
    modifier onlyRole(bytes32 role) {
        _onlyRole(role);
        _;
    }

    /// @dev Initializes the AccessManager with the specified parameters.
    /// @param admin_ The address of the initial admin.
    function __AccessManager_init(address admin_) internal onlyInitializing {
        __AccessManager_init_unchained(admin_);
    }

    /// @dev Grants the admin role to the initial admin.
    /// @param admin_ The address of the initial admin.
    function __AccessManager_init_unchained(
        address admin_
    ) internal onlyInitializing {
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @inheritdoc IAccessManager
    function grantRole(
        bytes32 role,
        address account
    ) public virtual onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @inheritdoc IAccessManager
    function revokeRole(
        bytes32 role,
        address account
    ) public virtual onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @dev Grants a role to an account if not already granted.
    /// @param role The role to grant.
    /// @param account The account receiving the role.
    function _grantRole(bytes32 role, address account) internal {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        if (!hasRole(role, account)) {
            $._roles[role][account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    /// @dev Revokes a role from an account if currently granted.
    /// @param role The role to revoke.
    /// @param account The account losing the role.
    function _revokeRole(bytes32 role, address account) internal {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        if (hasRole(role, account)) {
            $._roles[role][account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }

    /// @dev Reverts if the caller does not have the specified role.
    /// @param role The role required for the call.
    function _onlyRole(bytes32 role) internal view {
        if (!hasRole(role, _msgSender())) {
            revert Unauthorized();
        }
    }

    /// @inheritdoc IAccessManager
    function hasRole(
        bytes32 role,
        address account
    ) public view virtual returns (bool) {
        AccessManagerStorage storage $ = _getAccessManagerStorage();
        return $._roles[role][account];
    }
}
