// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITimelock} from "../interfaces/ITimelock.sol";

/// @title Timelock
/// @notice Allows delayed execution of queued transactions.
contract Timelock is Ownable2Step, ITimelock {
    /// @notice Minimum delay for queued transactions.
    uint256 public constant MIN_DELAY = 30 minutes;

    /// @notice Maximum delay for queued transactions.
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Time after the delay during which a queued transaction can be executed.
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @dev Queue status of transaction ids.
    mapping(bytes32 => bool) private _queued;

    /// @dev Current delay for queued transactions.
    uint256 private _delay;

    /// @dev Initializes the Timelock with the specified parameters.
    /// @param owner_ The address of the initial owner.
    /// @param delay_ The initial delay.
    constructor(address owner_, uint256 delay_) Ownable(owner_) {
        _setDelay(delay_);
    }

    receive() external payable {}

    /// @inheritdoc ITimelock
    function queue(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external onlyOwner returns (bytes32 txId) {
        if (timestamp < block.timestamp + _delay) {
            revert InvalidTimestamp();
        }

        txId = keccak256(abi.encode(target, value, data, timestamp));

        if (_queued[txId]) {
            revert AlreadyQueued();
        }
        _queued[txId] = true;

        emit Queued(txId, target, value, data, timestamp);
    }

    /// @inheritdoc ITimelock
    function cancel(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external onlyOwner {
        bytes32 txId = keccak256(abi.encode(target, value, data, timestamp));

        if (!_queued[txId]) {
            revert NotQueued();
        }
        _queued[txId] = false;

        emit Cancelled(txId, target, value, data, timestamp);
    }

    /// @inheritdoc ITimelock
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external payable onlyOwner returns (bytes memory returnData) {
        bytes32 txId = keccak256(abi.encode(target, value, data, timestamp));

        if (!_queued[txId]) {
            revert NotQueued();
        }
        if (block.timestamp < timestamp) {
            revert StillLocked();
        }
        if (block.timestamp > timestamp + GRACE_PERIOD) {
            revert Expired();
        }

        _queued[txId] = false;

        returnData = Address.functionCallWithValue(target, data, value);

        emit Executed(txId, target, value, data, timestamp);
    }

    /// @inheritdoc ITimelock
    function setDelay(uint256 delay) external {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _setDelay(delay);
    }

    /// @dev Updates the delay.
    /// @param delay The new delay.
    function _setDelay(uint256 delay) internal {
        if (delay < MIN_DELAY || delay > MAX_DELAY) {
            revert InvalidDelay();
        }
        _delay = delay;

        emit DelayUpdated(delay);
    }

    /// @inheritdoc ITimelock
    function getQueued(bytes32 txId) external view returns (bool) {
        return _queued[txId];
    }

    /// @inheritdoc ITimelock
    function getDelay() external view returns (uint256) {
        return _delay;
    }
}
