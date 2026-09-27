// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";

contract TickAccountantTest is TickFixture {
    function setUp() public override {
        super.setUp();
        _seedSystem(1_000_000 * ONE, 900_000 * ONE);
    }

    /*//////////////////////////////////////////////////////////////
                         HONEST COMMIT, HASH, IDS
    //////////////////////////////////////////////////////////////*/

    function testHonestTickIsAcceptedWithDerivedRates() public {
        _yield(hubSource, address(hubStrategy), 100 * ONE); // +0.01%
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        _commit(s, idx);

        ITickAccountant.Tick memory t = accountant.getTick(s.tickId);
        assertEq(uint8(t.status), uint8(ITickAccountant.TickStatus.Accepted));
        assertEq(t.navHash, keccak256(abi.encode(s)), "navHash commits to the canonical encoding");
        uint256 expectedNav = s.hubCash + s.positions[0].valueBid - s.pendingDeposits - s.liabilities;
        assertEq(t.navBid, expectedNav, "nav derived on-chain from positions");
        assertEq(t.rateBid, (expectedNav * WAD) / s.totalShares, "rate = nav / shares");
        assertGt(t.rateBid, WAD, "yield recognized");
        assertEq(accountant.lastAcceptedTickId(), s.tickId);
    }

    function testTickIdMustBeSequential() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.tickId += 1;
        vm.expectRevert(ITickAccountant.InvalidTickId.selector);
        _commit(s, idx);
    }

    function testAcceptedTickCannotBeRewritten() public {
        uint64 id = _tick();
        ITickAccountant.Tick memory before = accountant.getTick(id);

        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.tickId = id; // try to overwrite
        vm.expectRevert(ITickAccountant.InvalidTickId.selector);
        _commit(s, idx);

        _advance(60);
        _tick();
        ITickAccountant.Tick memory later = accountant.getTick(id);
        assertEq(keccak256(abi.encode(before)), keccak256(abi.encode(later)), "stored tick unchanged");
    }

    function testReferenceTimeRules() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);

        NavSnapshot.Snapshot memory future = s;
        future.referenceTime = uint64(block.timestamp + 1);
        vm.expectRevert(ITickAccountant.InvalidTime.selector);
        _commit(future, idx);

        uint64 prevRef = accountant.getTick(accountant.lastTickId()).referenceTime;
        s.referenceTime = prevRef; // not strictly after the previous tick
        vm.expectRevert(ITickAccountant.InvalidTime.selector);
        _commit(s, idx);
    }

    function testSnapshotOlderThanMaxAgeRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);
        vm.expectRevert(ITickAccountant.InvalidTime.selector);
        _commit(s, idx);
    }

    function testOnlyNavUpdaterCommits() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        vm.prank(attacker);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        accountant.commitTick(s, idx);
    }

    /*//////////////////////////////////////////////////////////////
                    HUB BINDING: UPDATER CANNOT MISREPORT
    //////////////////////////////////////////////////////////////*/

    function testUnderreportedLiabilitiesRejected() public {
        // create a liability: bob redeems through a cycle, not yet funded/claimed
        uint256 shares = vault.balanceOf(alice) / 10;
        _requestRedeem(alice, shares);
        _cycle();
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        assertGt(s.liabilities, 0, "fixture: liability exists");
        _advance(1);
        s.liabilities = 0;
        vm.expectRevert(ITickAccountant.HubStateMismatch.selector);
        _commit(s, idx);
    }

    function testUnderreportedSharesRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.totalShares -= 1;
        vm.expectRevert(ITickAccountant.HubStateMismatch.selector);
        _commit(s, idx);
    }

    function testHiddenPendingDepositsRejected() public {
        _requestDeposit(bob, 5_000 * ONE);
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.pendingDeposits = 0; // would count bob's pending cash as NAV
        vm.expectRevert(ITickAccountant.HubStateMismatch.selector);
        _commit(s, idx);
    }

    function testStaleCheckpointIndexRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        vm.expectRevert(ITickAccountant.HubStateMismatch.selector);
        _commit(s, idx - 1);
    }

    function testWrongHubBlockHashRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.chains[0].blockHash = keccak256("reorged");
        vm.expectRevert(ITickAccountant.InvalidHubReference.selector);
        _commit(s, idx);
    }

    function testHubBlockBeforePreviousCommitRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        _tick(); // commits in a later block
        s.tickId = accountant.lastTickId() + 1;
        s.referenceTime = uint64(block.timestamp);
        vm.expectRevert(ITickAccountant.InvalidHubReference.selector);
        _commit(s, idx);
    }

    function testUnknownAgentPositionRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.positions[0].holder = attacker;
        vm.expectRevert(ITickAccountant.UnknownAgent.selector);
        _commit(s, idx);
    }

    function testUnsortedOrDuplicatePositionsRejected() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        NavSnapshot.Position[] memory dup = new NavSnapshot.Position[](2);
        dup[0] = s.positions[0];
        dup[1] = s.positions[0];
        s.positions = dup;
        vm.expectRevert(NavSnapshot.UnsortedPositions.selector);
        _commit(s, idx);
    }

    function testChainSetMustMatch() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        NavSnapshot.ChainRef[] memory one = new NavSnapshot.ChainRef[](1);
        one[0] = s.chains[0];
        s.chains = one;
        vm.expectRevert(ITickAccountant.ChainSetMismatch.selector);
        _commit(s, idx);
    }

    /*//////////////////////////////////////////////////////////////
                     CORRIDOR, BUCKETS AND QUARANTINE
    //////////////////////////////////////////////////////////////*/

    function testOverstatedRemoteValueIsQuarantinedNotSettled() public {
        uint64 before = accountant.lastAcceptedTickId();
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        // malicious updater inflates the strategy position by 1% (> 0.5% bucket)
        s.positions[0].valueBid += s.positions[0].valueBid / 100;
        s.positions[0].valueOffer = s.positions[0].valueBid;
        _commit(s, idx);

        assertEq(uint8(accountant.getTick(s.tickId).status), uint8(ITickAccountant.TickStatus.Quarantined));
        assertEq(accountant.lastAcceptedTickId(), before, "settlement basis unchanged");
        assertTrue(accountant.frozen(), "breaker tripped");
        assertFalse(accountant.bridgeSendsAllowed());

        // a later honest tick in bounds of the last ACCEPTED tick resolves it
        _advance(60);
        uint64 honest = _tick();
        assertEq(accountant.lastAcceptedTickId(), honest);
        assertFalse(accountant.frozen());
    }

    function testRatifyMakesLargeRealMoveSettleable() public {
        _yield(hubSource, address(hubStrategy), 20_000 * ONE); // +2%, beyond bucket
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        _commit(s, idx);
        assertEq(uint8(accountant.getTick(s.tickId).status), uint8(ITickAccountant.TickStatus.Quarantined));

        vm.prank(attacker);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        accountant.ratifyTick(s.tickId);

        vm.prank(admin);
        accountant.ratifyTick(s.tickId);
        assertEq(uint8(accountant.getTick(s.tickId).status), uint8(ITickAccountant.TickStatus.Ratified));
        assertEq(accountant.lastAcceptedTickId(), s.tickId);
        assertFalse(accountant.frozen());
    }

    /// @dev Invariant 11: many individually small moves cannot exceed the bucket.
    function testManySmallUpMovesExhaustTheBucket() public {
        uint256 step = 3_600 * ONE; // +0.4% of ~900k strategy (+~0.36% of nav)
        _yield(hubSource, address(hubStrategy), step);
        _advance(60);
        uint64 first = _tick();
        assertEq(uint8(accountant.getTick(first).status), uint8(ITickAccountant.TickStatus.Accepted));

        _yield(hubSource, address(hubStrategy), step);
        _advance(60);
        uint64 second = _tick();
        assertEq(
            uint8(accountant.getTick(second).status),
            uint8(ITickAccountant.TickStatus.Quarantined),
            "second step within per-tick size but beyond remaining allowance"
        );
    }

    /// @dev Over any window W, recognized upward movement <= capacity + refill * W.
    function testFuzzCumulativeUpBound(uint8 steps, uint32 gapSeed, uint16 stepBpsSeed) public {
        steps = uint8(bound(steps, 2, 20));
        uint256 gap = bound(gapSeed, 60, 6 hours);
        uint256 stepBps = bound(stepBpsSeed, 1, 60); // 0.01% .. 0.6% of nav per step

        uint256 startRate = _lastTick().rateBid;
        uint256 startTime = block.timestamp;
        for (uint256 i; i < steps; i++) {
            (, ITickAccountant.Tick memory last) = accountant.latestAccepted();
            uint256 add = (uint256(last.navBid) * stepBps) / 10_000;
            _yield(hubSource, address(hubStrategy), add);
            _advance(gap);
            _tick();
        }
        uint256 endRate = _lastTick().rateBid;
        uint256 window = block.timestamp - startTime;
        ITickAccountant.Bucket memory up = _defaultUp();
        uint256 maxGrowth = up.capacity + up.refillPerSecond * window;
        // measured against the start rate; compounding makes the bound conservative
        uint256 growth = endRate > startRate ? ((endRate - startRate) * WAD) / startRate : 0;
        assertLe(growth, maxGrowth + maxGrowth / 50, "cumulative growth within bucket bound");
    }

    function testSmallLossAcceptedButFlagsDepositClearing() public {
        _loss(hubSource, address(hubStrategy), 1_500 * ONE); // -0.15% of nav
        _advance(60);
        uint64 id = _tick();
        ITickAccountant.Tick memory t = accountant.getTick(id);
        assertEq(uint8(t.status), uint8(ITickAccountant.TickStatus.Accepted));
        assertTrue(t.flags & accountant.FLAG_DOWN_BEYOND_DEPOSIT_LIMIT() != 0, "deposit clearing flagged");
        assertLt(t.rateBid, WAD);
    }

    function testLargeLossIsQuarantined() public {
        _loss(hubSource, address(hubStrategy), 50_000 * ONE); // -5%
        _advance(60);
        uint64 id = _tick();
        assertEq(uint8(accountant.getTick(id).status), uint8(ITickAccountant.TickStatus.Quarantined));
        assertTrue(accountant.frozen());
    }

    function testSpreadBound() public {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.positions[0].valueOffer = s.positions[0].valueBid * 2; // offer 2x bid
        _commit(s, idx);
        assertEq(uint8(accountant.getTick(s.tickId).status), uint8(ITickAccountant.TickStatus.Quarantined));
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    function testPerformanceFeeOnlyAboveHighWaterMark() public {
        accountant.setFees(0, 0.25e18);
        _yield(hubSource, address(hubStrategy), 1_000 * ONE);
        _advance(60);
        _tick();
        uint256 feeAfterGain = vault.balanceOf(treasury);
        assertGt(feeAfterGain, 0, "fee on new high");

        _loss(hubSource, address(hubStrategy), 800 * ONE);
        _advance(60);
        _tick();
        _yield(hubSource, address(hubStrategy), 800 * ONE); // recovery below the mark
        _advance(60);
        _tick();
        assertEq(vault.balanceOf(treasury), feeAfterGain, "no fee on recovery below HWM");
    }

    function testFeeIsChargedOnBidNotOffer() public {
        accountant.setFees(0, 0.25e18);
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.positions[0].valueOffer = s.positions[0].valueBid + 5_000 * ONE; // unrecognized upside
        _commit(s, idx);
        assertEq(vault.balanceOf(treasury), 0, "no fee on offer-only value");
    }

    /*//////////////////////////////////////////////////////////////
                              EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function testGuardianFreezesOnlyAdminUnfreezes() public {
        vm.prank(guardian);
        accountant.freeze();
        assertTrue(accountant.frozen());

        // an honest tick does not lift a guardian freeze
        _advance(60);
        _tick();
        assertTrue(accountant.frozen());

        vm.prank(guardian);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        accountant.unfreeze();

        vm.prank(admin);
        accountant.unfreeze();
        assertFalse(accountant.frozen());
    }
}
