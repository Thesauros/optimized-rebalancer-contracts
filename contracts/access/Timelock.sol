// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITimelock} from "../interfaces/ITimelock.sol";

/**
 * @title Timelock
 * @notice A time-delayed execution contract for critical operations
 * @dev This contract implements a governance mechanism that requires a time delay
 *      before executing critical operations, providing security against malicious
 *      or accidental changes to the protocol.
 *
 * @custom:security The timelock provides several security features:
 * - Minimum delay of 30 minutes prevents immediate execution
 * - Maximum delay of 30 days prevents indefinite delays
 * - Grace period of 14 days for execution after delay expires
 * - Only owner can queue and execute transactions
 * - Transactions can be cancelled before execution
 */
contract Timelock is Ownable2Step, ITimelock {
    /// @notice Minimum delay for queued transactions (30 minutes)
    /// @dev Prevents immediate execution of critical operations
    uint256 public constant MIN_DELAY = 30 minutes;

    /// @notice Maximum delay for queued transactions (30 days)
    /// @dev Prevents indefinite delays that could lock the protocol
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Grace period for executing queued transactions (14 days)
    /// @dev After this period, transactions expire and cannot be executed
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice Mapping of transaction IDs to their queued status
    /// @dev Transaction ID is computed as keccak256(abi.encode(target, value, signature, data, timestamp))
    mapping(bytes32 => bool) private _queued;

    /// @notice Current delay for queued transactions
    /// @dev Can be updated by the contract itself through setDelay()
    uint256 private _delay;

    /**
     * @dev Initializes the Timelock contract with the specified parameters.
     * @param owner_ The address of the initial owner of the contract.
     * @param delay_ The initial delay for queued transactions.
     */
    constructor(address owner_, uint256 delay_) Ownable(owner_) {
        _setDelay(delay_);
    }

    receive() external payable {}

    /**
     * @notice Queues a transaction for delayed execution
     * @param target The address of the contract to call
     * @param value The amount of ether to send with the call (0 for most calls)
     * @param data The ABI-encoded parameters for the function call (without function selector)
     * @param timestamp The timestamp when the transaction can be executed (must be >= block.timestamp + delay)
     * @return txId The unique transaction ID for this queued transaction
     *
     * @dev The transaction ID is computed as keccak256(abi.encode(target, value, signature, data, timestamp))
     * @dev The timestamp must be at least `delay` seconds in the future
     * @dev Only the contract owner can queue transactions
     */
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

    /**
     * @notice Cancels a queued transaction.
     * @param target The address of the contract to cancel the transaction for.
     * @param value The amount of ether that was to be sent with the call.
     * @param data The calldata for the function called on the target address.
     * @param timestamp The time when the transaction was scheduled to be executed.
     */
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

    /**
     * @notice Executes a previously queued transaction
     * @param target The address of the contract to call
     * @param value The amount of ether to send with the call
     * @param data The ABI-encoded parameters for the function call
     * @param timestamp The original timestamp when the transaction was queued
     * @return returnData The return data from the executed function call
     *
     * @dev The transaction must have been previously queued
     * @dev The current timestamp must be >= the execution timestamp
     * @dev The transaction must not have expired (timestamp + GRACE_PERIOD)
     * @dev Only the contract owner can execute transactions
     * @dev The transaction is removed from the queue after execution
     */
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

    /**
     * @notice Sets a new delay for queued transactions.
     * @param delay The new delay duration in seconds.
     */
    function setDelay(uint256 delay) external {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _setDelay(delay);
    }

    /**
     * @dev Internal function to set the delay.
     * @param delay The new delay duration in seconds.
     */
    function _setDelay(uint256 delay) internal {
        if (delay < MIN_DELAY || delay > MAX_DELAY) {
            revert InvalidDelay();
        }
        _delay = delay;

        emit DelayUpdated(delay);
    }

    /// @notice Returns whether a transaction is currently queued.
    function getQueued(bytes32 txId) external view returns (bool) {
        return _queued[txId];
    }

    /// @notice Returns the current delay applied when queueing new transactions.
    function getDelay() external view returns (uint256) {
        return _delay;
    }
}
