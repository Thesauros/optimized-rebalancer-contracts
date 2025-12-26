// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

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
 * 
 * @custom:usage Example usage:
 * ```solidity
 * // Queue a transaction to update vault providers
 * timelock.queue(
 *     vaultAddress,
 *     0,
 *     "setProviders(address[])",
 *     encodedData,
 *     block.timestamp + delay
 * );
 * 
 * // After delay period, execute the transaction
 * timelock.execute(
 *     vaultAddress,
 *     0,
 *     "setProviders(address[])",
 *     encodedData,
 *     executionTimestamp
 * );
 * ```
 */
contract Timelock is Ownable2Step {
    /**
     * @dev Errors
     */
    error Timelock__Unauthorized();
    error Timelock__InvalidDelay();
    error Timelock__InvalidTimestamp();
    error Timelock__NotQueued();
    error Timelock__StillLocked();
    error Timelock__Expired();
    error Timelock__ExecutionFailed();

    /// @notice Mapping of transaction IDs to their queued status
    /// @dev Transaction ID is computed as keccak256(abi.encode(target, value, signature, data, timestamp))
    mapping(bytes32 => bool) public queued;

    /// @notice Minimum delay for queued transactions (30 minutes)
    /// @dev Prevents immediate execution of critical operations
    uint256 public constant MIN_DELAY = 30 minutes;
    
    /// @notice Maximum delay for queued transactions (30 days)
    /// @dev Prevents indefinite delays that could lock the protocol
    uint256 public constant MAX_DELAY = 30 days;
    
    /// @notice Grace period for executing queued transactions (14 days)
    /// @dev After this period, transactions expire and cannot be executed
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice Current delay for queued transactions
    /// @dev Can be updated by the contract itself through setDelay()
    uint256 public delay;

    /**
     * @dev Emitted when the delay for queued transactions is updated.
     */
    event DelayUpdated(uint256 indexed newDelay);

    /**
     * @dev Emitted when a transaction is queued.
     */
    event Queued(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string signature,
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
        string signature,
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
        string signature,
        bytes data,
        uint256 timestamp
    );

    /**
     * @dev Reverts if called by any account other than the contract itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Timelock__Unauthorized();
        }
        _;
    }

    /**
     * @dev Initializes the Timelock contract with the specified parameters.
     * @param owner_ The address of the initial owner of the contract.
     * @param delay_ The initial delay for queued transactions.
     */
    constructor(address owner_, uint256 delay_) Ownable(owner_) {
        _setDelay(delay_);
    }

    receive() external payable {}

    fallback() external payable {}

    /**
     * @notice Queues a transaction for delayed execution
     * @param target The address of the contract to call
     * @param value The amount of ether to send with the call (0 for most calls)
     * @param signature The function signature of the target contract (e.g., "setProviders(address[])")
     * @param data The ABI-encoded parameters for the function call (without function selector)
     * @param timestamp The timestamp when the transaction can be executed (must be >= block.timestamp + delay)
     * @return txId The unique transaction ID for this queued transaction
     * 
     * @dev The transaction ID is computed as keccak256(abi.encode(target, value, signature, data, timestamp))
     * @dev The timestamp must be at least `delay` seconds in the future
     * @dev Only the contract owner can queue transactions
     * 
     * @custom:example
     * ```solidity
     * // Queue a transaction to update vault providers
     * bytes memory data = abi.encode(newProviders);
     * bytes32 txId = timelock.queue(
     *     vaultAddress,
     *     0,
     *     "setProviders(address[])",
     *     data,
     *     block.timestamp + 24 hours
     * );
     * ```
     */
    function queue(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 timestamp
    ) public onlyOwner returns (bytes32) {
        if (timestamp < block.timestamp + delay) {
            revert Timelock__InvalidTimestamp();
        }

        bytes32 txId = keccak256(
            abi.encode(target, value, signature, data, timestamp)
        );
        queued[txId] = true;

        emit Queued(txId, target, value, signature, data, timestamp);
        return txId;
    }

    /**
     * @notice Cancels a queued transaction.
     * @param target The address of the contract to cancel the transaction for.
     * @param value The amount of ether that was to be sent with the call.
     * @param signature The function signature of the target contract.
     * @param data The calldata for the function called on the target address.
     * @param timestamp The time when the transaction was scheduled to be executed.
     */
    function cancel(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 timestamp
    ) public onlyOwner {
        bytes32 txId = keccak256(
            abi.encode(target, value, signature, data, timestamp)
        );
        queued[txId] = false;

        emit Cancelled(txId, target, value, signature, data, timestamp);
    }

    /**
     * @notice Executes a previously queued transaction
     * @param target The address of the contract to call
     * @param value The amount of ether to send with the call
     * @param signature The function signature of the target contract
     * @param data The ABI-encoded parameters for the function call
     * @param timestamp The original timestamp when the transaction was queued
     * @return returnData The return data from the executed function call
     * 
     * @dev The transaction must have been previously queued
     * @dev The current timestamp must be >= the execution timestamp
     * @dev The transaction must not have expired (timestamp + GRACE_PERIOD)
     * @dev Only the contract owner can execute transactions
     * @dev The transaction is removed from the queue after execution
     * 
     * @custom:example
     * ```solidity
     * // Execute a previously queued transaction
     * bytes memory result = timelock.execute(
     *     vaultAddress,
     *     0,
     *     "setProviders(address[])",
     *     data,
     *     originalTimestamp
     * );
     * ```
     */
    function execute(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 timestamp
    ) public payable onlyOwner returns (bytes memory) {
        bytes32 txId = keccak256(
            abi.encode(target, value, signature, data, timestamp)
        );

        if (!queued[txId]) {
            revert Timelock__NotQueued();
        }
        if (block.timestamp < timestamp) {
            revert Timelock__StillLocked();
        }
        if (block.timestamp > timestamp + GRACE_PERIOD) {
            revert Timelock__Expired();
        }

        queued[txId] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(
                bytes4(keccak256(bytes(signature))),
                data
            );
        }
        (bool success, bytes memory returnData) = target.call{value: value}(
            callData
        );
        if (!success) {
            revert Timelock__ExecutionFailed();
        }

        emit Executed(txId, target, value, signature, data, timestamp);

        return returnData;
    }

    /**
     * @notice Sets a new delay for queued transactions.
     * @param _delay The new delay duration in seconds.
     */
    function setDelay(uint256 _delay) public onlySelf {
        _setDelay(_delay);
    }

    /**
     * @dev Internal function to set the delay.
     * @param _delay The new delay duration in seconds.
     */
    function _setDelay(uint256 _delay) internal {
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) {
            revert Timelock__InvalidDelay();
        }

        delay = _delay;
        emit DelayUpdated(_delay);
    }
}
