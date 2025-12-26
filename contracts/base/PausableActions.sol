// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title PausableActions
 * @notice Granular pausing mechanism for specific actions
 * @dev This contract provides fine-grained control over pausing specific actions
 *      rather than pausing the entire contract. It's inspired by OpenZeppelin's
 *      Pausable contract but allows for selective action pausing.
 * 
 * @custom:features The contract supports:
 * - Individual action pausing (Deposit, Withdraw)
 * - Granular control over different operations
 * - Event emission for pause/unpause actions
 * - Modifier-based access control
 * 
 * @custom:security Benefits:
 * - Prevents emergency situations from affecting all operations
 * - Allows selective disabling of problematic functions
 * - Maintains transparency through events
 * - Easy to extend with new action types
 * 
 * @custom:usage Example:
 * ```solidity
 * contract MyVault is PausableActions {
 *     function deposit() external whenNotPaused(Actions.Deposit) {
 *         // Deposit logic
 *     }
 *     
 *     function withdraw() external whenNotPaused(Actions.Withdraw) {
 *         // Withdraw logic
 *     }
 *     
 *     function emergencyPauseDeposits() external onlyOwner {
 *         _pause(Actions.Deposit);
 *     }
 * }
 * ```
 */
abstract contract PausableActions is Context {
    /**
     * @dev Errors
     */
    error PausableActions__ActionPaused();
    error PausableActions__ActionNotPaused();

    /// @notice Enumeration of pausable actions
    /// @dev Each action can be paused independently
    enum Actions {
        Deposit,  /// @dev Pausing deposits prevents new funds from entering the vault
        Withdraw  /// @dev Pausing withdrawals prevents users from exiting the vault
    }

    /// @notice Mapping of actions to their paused state
    /// @dev true = paused, false = active
    mapping(Actions => bool) private _actionPaused;

    /**
     * @dev Emitted when the pause is triggered by `account` for a specific `action`.
     */
    event Paused(address account, Actions action);

    /**
     * @dev Emitted when the pause is lifted by `account` for a specific `action`.
     */
    event Unpaused(address account, Actions action);

    /**
     * @dev Modifier to make a function callable only when the specified `action` is not paused.
     *
     * Requirements:
     *
     * - The action must not be paused.
     */
    modifier whenNotPaused(Actions action) {
        _requireNotPaused(action);
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the specified `action` is paused.
     *
     * Requirements:
     *
     * - The action must be paused.
     */
    modifier whenPaused(Actions action) {
        _requirePaused(action);
        _;
    }

    /**
     * @dev Returns true if the specified `action` is paused, and false otherwise.
     */
    function paused(Actions action) public view returns (bool) {
        return _actionPaused[action];
    }

    /**
     * @dev Throws if the specified `action` is paused.
     */
    function _requireNotPaused(Actions action) internal view {
        if (paused(action)) {
            revert PausableActions__ActionPaused();
        }
    }

    /**
     * @dev Throws if the specified `action` is not paused.
     */
    function _requirePaused(Actions action) internal view {
        if (!paused(action)) {
            revert PausableActions__ActionNotPaused();
        }
    }

    /**
     * @dev Triggers paused state for the specified `action`.
     *
     * Requirements:
     *
     * - The action must not be paused.
     */
    function _pause(Actions action) internal whenNotPaused(action) {
        _actionPaused[action] = true;
        emit Paused(_msgSender(), action);
    }

    /**
     * @dev Returns to normal state for the specified `action`.
     *
     * Requirements:
     *
     * - The action must be paused.
     */
    function _unpause(Actions action) internal whenPaused(action) {
        _actionPaused[action] = false;
        emit Unpaused(_msgSender(), action);
    }
}
