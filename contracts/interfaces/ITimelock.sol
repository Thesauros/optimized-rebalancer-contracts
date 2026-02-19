// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ITimelock {
    /// @dev The transaction timestamp is earlier than required.
    error InvalidTimestamp();

    /// @dev The transaction is already queued.
    error AlreadyQueued();

    /// @dev The transaction is not queued.
    error NotQueued();

    /// @dev The transaction cannot be executed yet.
    error StillLocked();

    /// @dev The transaction can no longer be executed.
    error Expired();

    /// @dev The caller is not the contract itself.
    error OnlySelf();

    /// @dev The delay is out of bounds.
    error InvalidDelay();

    /// @dev Emitted when the delay is updated.
    /// @param delay The new delay.
    event DelayUpdated(uint256 delay);

    /// @dev Emitted when a transaction is queued.
    /// @param txId The queued transaction id.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    event Queued(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    /// @dev Emitted when a queued transaction is cancelled.
    /// @param txId The queued transaction id.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    event Cancelled(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    /// @dev Emitted when a queued transaction is executed.
    /// @param txId The queued transaction id.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    event Executed(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    /// @notice Queues a transaction for delayed execution.
    /// @dev Caller must be the owner.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    /// @return The queued transaction id.
    function queue(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external returns (bytes32);

    /// @notice Cancels a queued transaction.
    /// @dev Caller must be the owner.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    function cancel(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external;

    /// @notice Executes a queued transaction.
    /// @dev Caller must be the owner.
    /// @param target The address of the contract to call.
    /// @param value The amount of ether to send with the call.
    /// @param data The calldata for the call.
    /// @param timestamp The timestamp at which the transaction becomes executable.
    /// @return The return data from the call.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external payable returns (bytes memory);

    /// @notice Sets the delay.
    /// @dev Caller must be the contract itself.
    /// @param delay The new delay.
    function setDelay(uint256 delay) external;

    /// @notice Returns whether a transaction is queued.
    /// @param txId The transaction id to check.
    /// @return True if the transaction is queued, false otherwise.
    function getQueued(bytes32 txId) external view returns (bool);

    /// @notice Returns the delay.
    /// @return The delay.
    function getDelay() external view returns (uint256);
}
