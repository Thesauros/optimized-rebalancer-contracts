// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IPausableActions} from "../interfaces/IPausableActions.sol";

/**
 * @title PausableActions
 *
 * @notice Granular pausing mechanism for specific actions.
 * @dev Inspired and modified from OpenZeppelin's Pausable contract.
 */
abstract contract PausableActions is ContextUpgradeable, IPausableActions {
    /// @custom:storage-location erc7201:thesauros.storage.PausableActions
    struct PausableActionsStorage {
        mapping(Actions => bool) _actionPaused;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.PausableActions")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PausableActionsStorageLocation =
        0x3269bba93b0c415a49697506f3e813e8145a2749219158acdaf45928901f6400;

    function _getPausableActionsStorage()
        private
        pure
        returns (PausableActionsStorage storage $)
    {
        assembly {
            $.slot := PausableActionsStorageLocation
        }
    }

    /// @dev Modifier to make a function callable only when the specified action is not paused.
    modifier whenNotPaused(Actions action) {
        _requireNotPaused(action);
        _;
    }

    /// @dev Modifier to make a function callable only when the specified action is paused.
    modifier whenPaused(Actions action) {
        _requirePaused(action);
        _;
    }

    /// @inheritdoc IPausableActions
    function pause(Actions action) external virtual;

    /// @inheritdoc IPausableActions
    function unpause(Actions action) external virtual;

    /// @dev Internal function to pause the specified action.
    function _pause(Actions action) internal whenNotPaused(action) {
        PausableActionsStorage storage $ = _getPausableActionsStorage();
        $._actionPaused[action] = true;
        emit Paused(_msgSender(), action);
    }

    /// @dev Internal function to unpause the specified action.
    function _unpause(Actions action) internal whenPaused(action) {
        PausableActionsStorage storage $ = _getPausableActionsStorage();
        $._actionPaused[action] = false;
        emit Unpaused(_msgSender(), action);
    }

    /// @dev Throws if the specified action is paused.
    function _requireNotPaused(Actions action) internal view {
        if (paused(action)) {
            revert ActionPaused();
        }
    }

    /// @dev Throws if the specified action is not paused.
    function _requirePaused(Actions action) internal view {
        if (!paused(action)) {
            revert ActionNotPaused();
        }
    }

    /// @inheritdoc IPausableActions
    function paused(Actions action) public view virtual returns (bool) {
        PausableActionsStorage storage $ = _getPausableActionsStorage();
        return $._actionPaused[action];
    }
}
