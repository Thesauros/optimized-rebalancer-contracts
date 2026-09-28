// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
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

    /**
     * @dev `setChains` drops a chain from the set but leaves its agent marks, so
     *      the agent check alone would still pass. Such a position would be
     *      counted by `totals` while being invisible to `chainBids`, understating
     *      per-chain exposure — hence the explicit chain-set membership check.
     */
    function testPositionOnUnlistedChainRejected() public {
        vm.prank(executor);
        vault.pushToAgent(60_000 * ONE); // the seed leaves the hub agent with no idle
        (, uint256 delivered) = _bridgeHubToSpoke(50_000 * ONE, 49_990 * ONE);
        _deliverToSpoke(delivered);

        uint64[] memory hubOnly = new uint64[](1);
        hubOnly[0] = HUB;
        accountant.setChains(hubOnly);
        assertTrue(accountant.isAgent(SPOKE, address(spokeAgent)), "the agent mark survives setChains");

        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        // the fixture always reports both chains; the accountant now knows one,
        // so the header set matches while a position still points at the dropped chain
        NavSnapshot.ChainRef[] memory hubOnlyRefs = new NavSnapshot.ChainRef[](1);
        hubOnlyRefs[0] = s.chains[0];
        s.chains = hubOnlyRefs;
        assertEq(s.chains.length, 1, "the spoke is out of the chain set");
        bool spokePosition = false;
        for (uint256 i; i < s.positions.length; i++) {
            if (s.positions[i].chainId == SPOKE) spokePosition = true;
        }
        assertTrue(spokePosition, "but its balance is still reported as a position");

        _advance(1);
        vm.expectRevert(ITickAccountant.UnknownChain.selector);
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

    /**
     * @dev A Tick rejected on the spread bound must not spend rate capacity.
     *      Capacity is the allowance for honest moves, so burning it on a
     *      rejected Tick would quarantine the next honest one as well and stall
     *      settlement until the bucket refills. The bid move here is inside the
     *      bucket, so the old ordering (consume, then test the spread) drained it.
     */
    function testSpreadRejectionSpendsNoBucket() public {
        _yield(hubSource, address(hubStrategy), 900 * ONE); // +0.09% of nav, inside 0.5%

        (ITickAccountant.Bucket memory before,) = accountant.buckets();
        (NavSnapshot.Snapshot memory bad, uint256 idx) = _buildSnapshot();
        _advance(1);
        bad.positions[0].valueOffer = bad.positions[0].valueBid * 2;
        _commit(bad, idx);
        assertEq(uint8(accountant.getTick(bad.tickId).status), uint8(ITickAccountant.TickStatus.Quarantined));

        (ITickAccountant.Bucket memory afterBucket,) = accountant.buckets();
        assertEq(afterBucket.level, before.level, "a rejected Tick spends no rate capacity");
        assertEq(afterBucket.updatedAt, before.updatedAt, "bucket untouched, not even refilled");

        // the capacity was preserved for the honest Tick, which also resolves the
        // quarantine
        _advance(60);
        uint64 id = _tick();
        assertEq(uint8(accountant.getTick(id).status), uint8(ITickAccountant.TickStatus.Accepted));
        assertFalse(accountant.frozen());
        assertGt(accountant.getTick(id).rateBid, WAD, "the yield was recognized");
    }

    /*//////////////////////////////////////////////////////////////
                          PER-CHAIN EXPOSURE CAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Zero is the default and disables the check, so a launch that starts
    ///      with everything on the hub is not blocked on day one.
    function testChainExposureDisabledByDefault() public {
        assertEq(accountant.maxChainExposure(), 0);
        _advance(60);
        uint64 id = _tick();
        assertEq(accountant.getTick(id).flags & accountant.FLAG_CHAIN_EXPOSURE(), 0);
        assertFalse(accountant.isChainOverExposed(HUB));
        assertTrue(accountant.chainSendAllowed(SPOKE));
    }

    function testChainExposureCapRejectsAboveWad() public {
        vm.expectRevert(ITickAccountant.InvalidConfig.selector);
        accountant.setMaxChainExposure(uint128(WAD) + 1);
    }

    /**
     * @dev The cap gates sends *into* a chain, never out of it and never
     *      settlement. The hub starts holding ~100% of NAV, so an 80% cap flags
     *      the hub, and the corrective move (hub -> spoke) must still go through.
     */
    function testOverExposedHubCanStillSendOut() public {
        accountant.setMaxChainExposure(0.8e18);
        _advance(60);
        uint64 id = _tick();

        ITickAccountant.Tick memory t = accountant.getTick(id);
        assertTrue(t.flags & accountant.FLAG_CHAIN_EXPOSURE() != 0, "hub is over the cap");
        assertTrue(accountant.isChainOverExposed(HUB));
        assertFalse(accountant.isChainOverExposed(SPOKE));
        assertTrue(accountant.bridgeSendsAllowed(), "concentration does not trip the global breaker");
        assertFalse(accountant.chainSendAllowed(HUB), "nothing may be sent further into the hub");
        assertTrue(accountant.chainSendAllowed(SPOKE), "capital may leave for a chain under the cap");

        vm.prank(executor);
        vault.pushToAgent(100_000 * ONE);
        (bytes32 transferId,) = _bridgeHubToSpoke(100_000 * ONE, 99_900 * ONE);
        assertNotEq(transferId, bytes32(0), "the corrective send went through");
        assertEq(hubAgent.getSent(transferId).amount, uint128(100_000 * ONE));
    }

    /**
     * @dev The cap is measured against gross bid assets, not NAV. Netting off
     *      liabilities would inflate every chain's apparent share, so a large
     *      cleared redemption queue would latch the flag even though nothing moved
     *      between chains. Here the split stays roughly even while a 400k
     *      redemption becomes a liability: NAV falls from ~1M to ~600k, which
     *      would put the hub at ~92% of NAV but leaves it at ~55% of gross.
     */
    function testChainExposureUsesGrossAssetsNotNav() public {
        vm.prank(executor);
        hubAgent.deallocate(450_000 * ONE);
        (, uint256 index) = _bridgeHubToSpoke(450_000 * ONE, 449_900 * ONE);
        _deliverToSpoke(index);
        uint256 spokeIdle = spokeAgent.idle();
        vm.chainId(SPOKE);
        vm.prank(executor);
        spokeAgent.allocate(spokeIdle);
        vm.chainId(HUB);

        accountant.setMaxChainExposure(0.6e18);
        _advance(60);
        uint64 id = _tick();
        assertEq(accountant.getTick(id).flags & accountant.FLAG_CHAIN_EXPOSURE(), 0, "an even split is under the cap");

        _requestRedeem(alice, 400_000 * ONE);
        _cycle(); // clears it into liabilities; nobody claims, so they stay owed
        _advance(60);
        id = _tick();
        (,, uint256 liabilities,,,) = vault.accounting();
        assertGt(liabilities, 300_000 * ONE, "the redemption really became a liability");
        assertEq(accountant.getTick(id).flags & accountant.FLAG_CHAIN_EXPOSURE(), 0, "netting liabilities must not move the cap");
        assertTrue(accountant.chainSendAllowed(SPOKE), "sends stay open");
    }

    /// @dev The same cap from the other side: once the spoke holds most of the
    ///      NAV, the hub agent may not push more into it.
    function testOverExposedSpokeRefusesInboundSends() public {
        vm.prank(executor);
        hubAgent.deallocate(800_000 * ONE);
        (bytes32 sent, uint256 index) = _bridgeHubToSpoke(800_000 * ONE, 799_900 * ONE);
        _deliverToSpoke(index);
        // read idle before the prank: a view call in the argument list would
        // consume it
        uint256 spokeIdle = spokeAgent.idle();
        assertEq(spokeIdle, 800_000 * ONE, "the transfer landed on the spoke");
        vm.chainId(SPOKE);
        vm.prank(executor);
        spokeAgent.allocate(spokeIdle);
        vm.chainId(HUB);

        accountant.setMaxChainExposure(0.6e18);
        _advance(60);
        uint64 id = _tick();
        assertTrue(accountant.getTick(id).flags & accountant.FLAG_CHAIN_EXPOSURE() != 0);
        assertTrue(accountant.isChainOverExposed(SPOKE), "the spoke holds ~80%");
        assertFalse(accountant.isChainOverExposed(HUB));
        assertFalse(accountant.chainSendAllowed(SPOKE));

        vm.prank(executor);
        vault.pushToAgent(50_000 * ONE);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.SendsHalted.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 50_000 * ONE, 49_990 * ONE, keccak256("rebalance"));
        assertEq(hubAgent.getSent(sent).amount, uint128(800_000 * ONE), "the earlier send is untouched");
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
