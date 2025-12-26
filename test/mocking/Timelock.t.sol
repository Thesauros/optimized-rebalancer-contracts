// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Timelock} from "../../contracts/Timelock.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract TimelockTests is MockingUtilities {
    address public target;
    string public signature;
    uint256 public timestamp;

    event DelayUpdated(uint256 indexed newDelay);
    event Queued(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 timestamp
    );
    event Cancelled(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 timestamp
    );
    event Executed(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 timestamp
    );

    function setUp() public {
        target = address(timelock);
        signature = "setDelay(uint256)";
        timestamp = block.timestamp + TIMELOCK_DELAY;
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructor() public view {
        assertEq(timelock.owner(), address(this));
        assertEq(timelock.delay(), TIMELOCK_DELAY);
    }

    // =========================================
    // queue
    // =========================================

    function testQueueRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
        timelock.queue(target, 0, signature, data, timestamp);
    }

    function testQueueRevertsIfTimestampIsInvalid() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        uint256 invalidTimestamp = timestamp - 1;

        vm.expectRevert(Timelock.Timelock__InvalidTimestamp.selector);
        timelock.queue(target, 0, signature, data, invalidTimestamp);
    }

    function testQueue() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        assertTrue(timelock.queued(txId));
    }

    function testQueueEmitsEvent() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        vm.expectEmit();
        emit Queued(txId, target, 0, signature, data, timestamp);
        timelock.queue(target, 0, signature, data, timestamp);
    }

    // =========================================
    // cancel
    // =========================================

    function testCancelRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
        timelock.cancel(target, 0, signature, data, timestamp);
    }

    function testCancel() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        assertTrue(timelock.queued(txId));

        timelock.cancel(target, 0, signature, data, timestamp);

        assertFalse(timelock.queued(txId));
    }

    function testCancelEmitsEvent() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        vm.expectEmit();
        emit Cancelled(txId, target, 0, signature, data, timestamp);
        timelock.cancel(target, 0, signature, data, timestamp);
    }

    // =========================================
    // execute
    // =========================================

    function testExecuteRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
        timelock.execute(target, 0, signature, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsNotQueued() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.expectRevert(Timelock.Timelock__NotQueued.selector);
        timelock.execute(target, 0, signature, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsStillLocked() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        timelock.execute(target, 0, signature, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsExpired() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        vm.warp(timestamp + TIMELOCK_GRACE_PERIOD + 1);

        vm.expectRevert(Timelock.Timelock__Expired.selector);
        timelock.execute(target, 0, signature, data, timestamp);
    }

    function testExecuteRevertsIfTargetExecutionFails() public {
        uint256 invalidDelay = 1 seconds;
        bytes memory invalidData = abi.encode(invalidDelay);

        timelock.queue(target, 0, signature, invalidData, timestamp);

        vm.warp(timestamp);

        vm.expectRevert(Timelock.Timelock__ExecutionFailed.selector);
        timelock.execute(target, 0, signature, invalidData, timestamp);
    }

    function testExecute() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        vm.warp(timestamp);

        timelock.execute(target, 0, signature, data, timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        assertFalse(timelock.queued(txId));
        assertEq(timelock.delay(), newDelay);
    }

    function testExecuteEmitsEvent() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        timelock.queue(target, 0, signature, data, timestamp);

        vm.warp(timestamp);

        bytes32 txId = keccak256(
            abi.encode(target, 0, signature, data, timestamp)
        );

        vm.expectEmit();
        emit DelayUpdated(newDelay);
        emit Executed(txId, target, 0, signature, data, timestamp);
        timelock.execute(target, 0, signature, data, timestamp);
    }

    // =========================================
    // setDelay
    // =========================================

    function testSetDelayRevertsIfCallerIsNotTimelock() public {
        uint256 newDelay = 1 days;

        vm.expectRevert(Timelock.Timelock__Unauthorized.selector);
        timelock.setDelay(newDelay);
    }
}
