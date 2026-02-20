// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITimelock} from "../../contracts/interfaces/ITimelock.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract TimelockTests is MockingBase {
    uint256 internal constant MIN_DELAY = 30 minutes;
    uint256 internal constant MAX_DELAY = 30 days;
    uint256 internal constant GRACE_PERIOD = 14 days;

    Timelock public timelock;

    uint256 public initialDelay;

    address public target;
    uint256 public timestamp;

    uint256 public delay;
    bytes public data;

    function setUp() public override {
        initialDelay = DAY;

        timelock = new Timelock(address(this), initialDelay);

        target = address(timelock);
        timestamp = block.timestamp + initialDelay;

        delay = 30 minutes;
        data = abi.encodeWithSelector(ITimelock.setDelay.selector, delay);
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructor() public view {
        assertEq(timelock.owner(), address(this));
        assertEq(timelock.getDelay(), initialDelay);
    }

    // =========================================
    // queue
    // =========================================

    function testQueueRevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        timelock.queue(target, 0, data, timestamp);
    }

    function testQueueRevertsIfTimestampIsInvalid() public {
        uint256 invalidTimestamp = timestamp - 1;

        vm.expectRevert(ITimelock.InvalidTimestamp.selector);
        timelock.queue(target, 0, data, invalidTimestamp);
    }

    function testQueueRevertsIfAlreadyQueued() public {
        timelock.queue(target, 0, data, timestamp);

        vm.expectRevert(ITimelock.AlreadyQueued.selector);
        timelock.queue(target, 0, data, timestamp);
    }

    function testQueue() public {
        bytes32 txId = timelock.queue(target, 0, data, timestamp);

        assertTrue(timelock.getQueued(txId));
    }

    function testQueueEmitsEvent() public {
        bytes32 txId = keccak256(abi.encode(target, 0, data, timestamp));

        vm.expectEmit(address(timelock));
        emit ITimelock.Queued(txId, target, 0, data, timestamp);
        timelock.queue(target, 0, data, timestamp);
    }

    // =========================================
    // cancel
    // =========================================

    function testCancelRevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        timelock.cancel(target, 0, data, timestamp);
    }

    function testCancelRevertsIfTransactionIsNotQueued() public {
        vm.expectRevert(ITimelock.NotQueued.selector);
        timelock.cancel(target, 0, data, timestamp);
    }

    function testCancel() public {
        bytes32 txId = timelock.queue(target, 0, data, timestamp);
        
        timelock.cancel(target, 0, data, timestamp);

        assertFalse(timelock.getQueued(txId));
    }

    function testCancelEmitsEvent() public {
        bytes32 txId = timelock.queue(target, 0, data, timestamp);

        vm.expectEmit(address(timelock));
        emit ITimelock.Cancelled(txId, target, 0, data, timestamp);
        timelock.cancel(target, 0, data, timestamp);
    }

    // =========================================
    // execute
    // =========================================

    function testExecuteRevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        timelock.execute(target, 0, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsNotQueued() public {
        vm.expectRevert(ITimelock.NotQueued.selector);
        timelock.execute(target, 0, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsStillLocked() public {
        timelock.queue(target, 0, data, timestamp);

        vm.expectRevert(ITimelock.StillLocked.selector);
        timelock.execute(target, 0, data, timestamp);
    }

    function testExecuteRevertsIfTransactionIsExpired() public {
        timelock.queue(target, 0, data, timestamp);

        skip(initialDelay + GRACE_PERIOD + 1);

        vm.expectRevert(ITimelock.Expired.selector);
        timelock.execute(target, 0, data, timestamp);
    }

    function testExecuteRevertsIfTargetReverts(uint256 invalidDelay) public {
        vm.assume(invalidDelay < MIN_DELAY || invalidDelay > MAX_DELAY);
        bytes memory invalidData = abi.encodeWithSelector(
            ITimelock.setDelay.selector,
            invalidDelay
        );

        timelock.queue(target, 0, invalidData, timestamp);

        skip(initialDelay);

        vm.expectRevert(ITimelock.InvalidDelay.selector);
        timelock.execute(target, 0, invalidData, timestamp);
    }

    function testExecute() public {
        bytes32 txId = timelock.queue(target, 0, data, timestamp);

        skip(initialDelay);

        timelock.execute(target, 0, data, timestamp);

        assertFalse(timelock.getQueued(txId));
        assertEq(timelock.getDelay(), delay);
    }

    function testExecuteEmitsEvents() public {
        bytes32 txId = timelock.queue(target, 0, data, timestamp);

        skip(initialDelay);

        vm.expectEmit(address(timelock));
        emit ITimelock.DelayUpdated(delay);
        vm.expectEmit(address(timelock));
        emit ITimelock.Executed(txId, target, 0, data, timestamp);
        timelock.execute(target, 0, data, timestamp);
    }

    // =========================================
    // setDelay
    // =========================================

    function testSetDelayRevertsIfCallerIsNotTimelock() public {
        vm.expectRevert(ITimelock.OnlySelf.selector);
        timelock.setDelay(delay);
    }
}
