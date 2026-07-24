// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IAccessManager {
    error Unauthorized();

    /// @dev Emitted when an account is granted a role.
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );
    /// @dev Emitted when an account is revoked a role.
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;
}
