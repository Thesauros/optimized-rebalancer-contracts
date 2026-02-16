// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface ITimelock {
    /**
     * @dev Errors
     */
    error InvalidTimestamp();
    error AlreadyQueued();
    error NotQueued();
    error StillLocked();
    error Expired();
    error OnlySelf();
    error InvalidDelay();

    /**
     * @dev Emitted when the delay for queued transactions is updated.
     */
    event DelayUpdated(uint256 delay);

    /**
     * @dev Emitted when a transaction is queued.
     */
    event Queued(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a queued transaction is cancelled.
     */
    event Cancelled(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a queued transaction is executed.
     */
    event Executed(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 timestamp
    );

    function queue(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external returns (bytes32);

    function cancel(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external;

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp
    ) external payable returns (bytes memory);

    function setDelay(uint256 delay) external;

    function getQueued(bytes32 txId) external view returns (bool);

    function getDelay() external view returns (uint256);
}
