// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPausableActions {
    error ActionPaused();
    error ActionNotPaused();

    /// @dev Enumeration of pausable actions
    enum Actions {
        Deposit,
        Withdraw
    }

    /// @dev Emitted when the pause is triggered by an account for a specific action.
    event Paused(address account, Actions action);

    /// @dev Emitted when the pause is lifted by an account for a specific action.
    event Unpaused(address account, Actions action);

    /// @notice Pauses the specified action in the vault.
    function pause(Actions action) external;

    /// @notice Unpauses the specified action in the vault.
    function unpause(Actions action) external;

    /// @dev Returns true if the specified action is paused, and false otherwise.
    function paused(Actions action) external view returns (bool);
}
