// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IAccessManager {
    /// @dev The caller does not have the required role.
    error Unauthorized();

    /// @dev Emitted when an account is granted a role.
    /// @param role The role granted.
    /// @param account The account receiving the role.
    /// @param sender The caller.
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    /// @dev Emitted when a role is revoked from an account.
    /// @param role The role revoked.
    /// @param account The account losing the role.
    /// @param sender The caller.
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    /// @notice Returns whether an account has a role.
    /// @param role The role to check.
    /// @param account The account to check.
    /// @return True if the account has the role, false otherwise.
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);

    /// @notice Grants a role to an account.
    /// @dev Caller must have the admin role.
    /// @param role The role to grant.
    /// @param account The account receiving the role.
    function grantRole(bytes32 role, address account) external;

    /// @notice Revokes a role from an account.
    /// @dev Caller must have the admin role.
    /// @param role The role to revoke.
    /// @param account The account losing the role.
    function revokeRole(bytes32 role, address account) external;
}
