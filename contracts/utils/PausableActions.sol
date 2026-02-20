// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IPausableActions} from "../interfaces/IPausableActions.sol";

/// @title PausableActions
/// @notice Allows granular pausing of actions.
/// @dev Inspired and modified from OpenZeppelin's Pausable contract.
abstract contract PausableActions is ContextUpgradeable, IPausableActions {
    /// @custom:storage-location erc7201:thesauros.storage.PausableActions
    struct PausableActionsStorage {
        mapping(Actions => bool) _actionPaused;
    }

    // keccak256(abi.encode(uint256(keccak256("thesauros.storage.PausableActions")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PausableActionsStorageLocation =
        0x3269bba93b0c415a49697506f3e813e8145a2749219158acdaf45928901f6400;

    /// @dev Returns the ERC-7201 namespaced storage pointer.
    function _getPausableActionsStorage()
        private
        pure
        returns (PausableActionsStorage storage $)
    {
        assembly {
            $.slot := PausableActionsStorageLocation
        }
    }

    /// @dev Checks that the specified action is not paused.
    /// @param action The action to check.
    modifier whenNotPaused(Actions action) {
        _requireNotPaused(action);
        _;
    }

    /// @dev Checks that the specified action is paused.
    /// @param action The action to check.
    modifier whenPaused(Actions action) {
        _requirePaused(action);
        _;
    }

    /// @inheritdoc IPausableActions
    function pause(Actions action) external virtual;

    /// @inheritdoc IPausableActions
    function unpause(Actions action) external virtual;

    /// @dev Updates the pause state to paused.
    /// @param action The action to pause.
    function _pause(Actions action) internal whenNotPaused(action) {
        PausableActionsStorage storage $ = _getPausableActionsStorage();
        $._actionPaused[action] = true;
        emit Paused(_msgSender(), action);
    }

    /// @dev Updates the pause state to unpaused.
    /// @param action The action to unpause.
    function _unpause(Actions action) internal whenPaused(action) {
        PausableActionsStorage storage $ = _getPausableActionsStorage();
        $._actionPaused[action] = false;
        emit Unpaused(_msgSender(), action);
    }

    /// @dev Reverts if the specified action is paused.
    /// @param action The action to check.
    function _requireNotPaused(Actions action) internal view {
        if (paused(action)) {
            revert ActionPaused();
        }
    }

    /// @dev Reverts if the specified action is not paused.
    /// @param action The action to check.
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
