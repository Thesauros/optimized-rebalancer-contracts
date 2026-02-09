// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract TimelockTests is MockingBase {
    uint256 public constant GRACE_PERIOD = 14 days;

    Timelock public timelock;
    uint256 public delay;

    address public target;
    string public signature;
    uint256 public timestamp;

    function setUp() public override {
        delay = 30 minutes;

        timelock = new Timelock(address(this), delay);

        target = address(timelock);
        signature = "setDelay(uint256)";
        timestamp = block.timestamp + delay;
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructor() public view {
        assertEq(timelock.owner(), address(this));
        assertEq(timelock.delay(), delay);
    }

    // =========================================
    // queue
    // =========================================

    function testQueueRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
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

        vm.expectEmit(address(timelock));
        emit Timelock.Queued(txId, target, 0, signature, data, timestamp);
        timelock.queue(target, 0, signature, data, timestamp);
    }

    // =========================================
    // cancel
    // =========================================

    function testCancelRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
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

        vm.expectEmit(address(timelock));
        emit Timelock.Cancelled(txId, target, 0, signature, data, timestamp);
        timelock.cancel(target, 0, signature, data, timestamp);
    }

    // =========================================
    // execute
    // =========================================

    function testExecuteRevertsIfCallerIsNotOwner() public {
        uint256 newDelay = 1 days;
        bytes memory data = abi.encode(newDelay);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
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

        vm.warp(timestamp + GRACE_PERIOD + 1);

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

        vm.expectEmit(address(timelock));
        emit Timelock.DelayUpdated(newDelay);
        emit Timelock.Executed(txId, target, 0, signature, data, timestamp);
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
