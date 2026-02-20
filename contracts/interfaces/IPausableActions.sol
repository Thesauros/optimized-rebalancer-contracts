// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IPausableActions {
    /// @dev The action is paused.
    error ActionPaused();

    /// @dev The action is not paused.
    error ActionNotPaused();

    /// @dev Enumeration of pausable actions.
    enum Actions {
        Deposit,
        Withdraw
    }

    /// @dev Emitted when an action is paused.
    /// @param account The caller.
    /// @param action The action paused.
    event Paused(address account, Actions action);

    /// @dev Emitted when an action is unpaused.
    /// @param account The caller.
    /// @param action The action unpaused.
    event Unpaused(address account, Actions action);

    /// @notice Pauses an action.
    /// @param action The action to pause.
    function pause(Actions action) external;

    /// @notice Unpauses an action.
    /// @param action The action to unpause.
    function unpause(Actions action) external;

    /// @notice Returns whether an action is paused.
    /// @param action The action to check.
    /// @return True if the action is paused, false otherwise.
    function paused(Actions action) external view returns (bool);
}
