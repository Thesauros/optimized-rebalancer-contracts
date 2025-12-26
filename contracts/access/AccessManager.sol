// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title AccessManager
 *
 * @dev Inspired and modified from OpenZeppelin's AccessControl contract.
 */
contract AccessManager is Context {
    /**
     * @dev Errors
     */
    error AccessManager__CallerIsNotAdmin();
    error AccessManager__CallerIsNotOperator();
    error AccessManager__CallerIsNotExecutor();

    mapping(bytes32 role => mapping(address account => bool)) private _roles;

    bytes32 public constant ADMIN_ROLE = 0x00;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /**
     * @dev Emitted when `account` is granted `role`.
     */
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    /**
     * @dev Emitted when `account` is revoked `role`.
     */
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    /**
     * @dev Modifier that checks that an account has an admin role. Reverts
     * with an {AccessManager__CallerIsNotAdmin} error.
     */
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, _msgSender())) {
            revert AccessManager__CallerIsNotAdmin();
        }
        _;
    }

    /**
     * @dev Modifier that checks that an account has an operator role. Reverts
     * with an {AccessManager__CallerIsNotOperator} error.
     */
    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) {
            revert AccessManager__CallerIsNotOperator();
        }
        _;
    }

    /**
     * @dev Modifier that checks that an account has an executor role. Reverts
     * with an {AccessManager__CallerIsNotExecutor} error.
     */
    modifier onlyExecutor() {
        if (!hasRole(EXECUTOR_ROLE, _msgSender())) {
            revert AccessManager__CallerIsNotExecutor();
        }
        _;
    }

    /**
     * @dev Sets the deployer of the contract as the initial admin.
     */
    constructor() {
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(
        bytes32 role,
        address account
    ) public view virtual returns (bool) {
        return _roles[role][account];
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have the admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public onlyAdmin {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have the admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public onlyAdmin {
        _revokeRole(role, account);
    }

    /**
     * @dev Attempts to grant `role` to `account`.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal {
        if (!hasRole(role, account)) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    /**
     * @dev Attempts to revoke `role` from `account`.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal {
        if (hasRole(role, account)) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }
}
