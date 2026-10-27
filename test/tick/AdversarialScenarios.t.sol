// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IEpochVault} from "../../contracts/tick/interfaces/IEpochVault.sol";

/**
 * @notice Scenario list of docs/tick-accounting-design.md §15 / brief §32.
 */
contract AdversarialScenariosTest is TickFixture {
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();
        aliceShares = _seedSystem(1_000_000 * ONE, 800_000 * ONE);
    }

    /// @dev Invariant 9 / T20: knowing a positive Tick is coming gives nothing,
    ///      whether the deposit lands one block before or one block after it.
    function testDepositAroundPositiveTickIsNotProfitable() public {
        uint256 before = 100_000 * ONE;
        uint256 idBefore = _requestDeposit(attacker, before);

        _yield(hubSource, address(hubStrategy), 2_000 * ONE); // known upcoming +0.2%
        _advance(1 hours);
        _tick(); // the "favourable" tick, before cutoff
        uint256 idAfter = _requestDeposit(carol, before); // one block after it
        _advance(1);
        vault.closeEpoch();
        _advance(60);
        _tick();
        _advance(1);
        vault.clearDeposits();

        uint256 sharesBefore = vault.claim(idBefore);
        uint256 sharesAfter = vault.claim(idAfter);
        assertEq(sharesBefore, sharesAfter, "timing relative to the tick is irrelevant");

        // immediate exit: instant path pays bid - fee <= offer paid
        vm.prank(attacker);
        uint256 out = vault.instantRedeem(sharesBefore / 20, attacker, attacker, 0);
        assertLe(out * 20, before, "round trip does not profit");
    }

    /// @dev T21 for a positive move: requesting just before a positive Tick does
    ///      not capture the gain; it stays with remaining holders.
    function testRedeemBeforePositiveTickForgoesTheGain() public {
        uint256 openRate = vault.getEpoch(vault.currentEpoch()).openRateBid;
        uint256 id = _requestRedeem(alice, 100_000 * ONE);
        _yield(hubSource, address(hubStrategy), 2_000 * ONE);
        _cycle();
        vm.prank(executor);
        hubAgent.deallocate(200_000 * ONE);
        vm.prank(executor);
        hubAgent.returnToVault(200_000 * ONE);
        assertEq(vault.claim(id), (100_000 * ONE * openRate) / WAD);
    }

    /// @dev A transfer delayed across several Ticks and an epoch clearing is
    ///      counted exactly once: bid at minReceive, offer at amount sent.
    function testBridgeDelayedAcrossTicksAndEpochClearing() public {
        vm.prank(executor);
        hubAgent.deallocate(300_000 * ONE);
        (, uint256 idx) = _bridgeHubToSpoke(300_000 * ONE, 299_000 * ONE);

        _advance(60);
        uint64 t1 = _tick();
        ITickAccountant.Tick memory a = accountant.getTick(t1);
        assertEq(a.navOffer - a.navBid, 1_000 * ONE, "spread = sent - minReceive");

        // an epoch clears while the transfer is still in flight
        uint256 dep = _requestDeposit(bob, 10_000 * ONE);
        uint256 red = _requestRedeem(alice, 10_000 * ONE);
        _cycle();
        uint256 shares = vault.claim(dep);
        IEpochVault.Epoch memory e = vault.getEpoch(vault.currentEpoch() - 1);
        assertEq(shares, (10_000 * ONE * WAD) / e.rateOffer, "entry priced at offer (in flight at full value)");
        assertLe(e.priceRedeem, accountant.getTick(e.redeemTickId).rateBid, "exit priced at bid (in flight at minReceive)");
        vault.claim(red);

        // delivery: bid recognizes the full amount, offer unchanged
        _deliverToSpoke(idx);
        _advance(60);
        uint64 t2 = _tick();
        ITickAccountant.Tick memory b = accountant.getTick(t2);
        assertEq(b.navOffer, b.navBid, "no uncertainty once received");
    }

    /// @dev Overdue in-flight beyond the configured threshold halts deposit clearing
    ///      and hub sends, while redemptions still clear.
    function testOverdueTransferHaltsEntriesNotExits() public {
        ITickAccountant.Config memory c = _defaultConfig();
        c.maxOverdueInFlight = 0;
        accountant.setConfig(c);

        vm.prank(executor);
        hubAgent.deallocate(100_000 * ONE);
        _bridgeHubToSpoke(100_000 * ONE, 100_000 * ONE);

        _requestDeposit(bob, 10_000 * ONE);
        _requestRedeem(alice, 10_000 * ONE);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        _advance(1 hours); // transfer now older than maxTransit
        uint64 id = _tick();
        assertTrue(accountant.getTick(id).flags & accountant.FLAG_OVERDUE_IN_FLIGHT() != 0);
        assertFalse(accountant.bridgeSendsAllowed());

        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();
        vault.clearRedeems();
    }

    /// @dev amountReceived < amountSent: the shortfall becomes a recognized loss
    ///      at the next Tick, never a phantom asset.
    function testBridgeShortfallIsRecognized() public {
        wire.setFeeBps(10); // 0.1%
        vm.prank(executor);
        hubAgent.deallocate(100_000 * ONE);
        _advance(60);
        uint64 t0 = _tick();
        (, uint256 idx) = _bridgeHubToSpoke(100_000 * ONE, 99_500 * ONE);
        _deliverToSpoke(idx);
        _advance(60);
        uint64 t1 = _tick();
        assertEq(accountant.getTick(t0).navBid - accountant.getTick(t1).navBid, 100 * ONE, "fee recognized as loss");
    }

    /// @dev T1/T2: a compromised updater inflating remote value as fast as the
    ///      buckets allow, with an accomplice redeeming, extracts at most the
    ///      bucket allowance, and the queue price is capped by the epoch-open rate.
    function testCompromisedUpdaterExtractionIsBounded() public {
        uint256 id = _requestRedeem(alice, 500_000 * ONE);
        uint256 openRate = vault.getEpoch(vault.currentEpoch()).openRateBid;

        // inflate by 0.45% (just inside the up bucket) with fake value
        _advance(1 hours);
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        s.positions[0].valueBid += 4_500 * ONE;
        s.positions[0].valueOffer = s.positions[0].valueBid;
        _commit(s, idx);
        vault.closeEpoch();

        _advance(60);
        (s, idx) = _buildSnapshot();
        _advance(1);
        s.positions[0].valueBid += 4_500 * ONE;
        s.positions[0].valueOffer = s.positions[0].valueBid;
        _commit(s, idx); // stays accepted: the fake value only persists, no new move
        vault.clearRedeems();

        IEpochVault.Epoch memory e = vault.getEpoch(vault.currentEpoch() - 1);
        assertEq(e.priceRedeem, openRate, "queued exit capped at the open rate despite inflated bid");
        id;
    }

    /// @dev Mass withdrawal larger than the buffer: nothing is bridged synchronously;
    ///      the epoch waits, then funds FIFO once capital returns.
    function testMassWithdrawalExceedsBuffer() public {
        uint256 id = _requestRedeem(alice, aliceShares); // everything
        uint64 epochId = _cycle();
        assertFalse(vault.getEpoch(epochId).funded);
        vm.startPrank(executor);
        // minAssets 0: this test is about the recall path, not about slippage
        hubAgent.deallocateShares(hubAgent.strategyShares(), 0);
        hubAgent.returnToVault(usdc.balanceOf(address(hubAgent)));
        vm.stopPrank();
        assertTrue(vault.getEpoch(epochId).funded);
        uint256 paid = vault.claim(id);
        assertLe(paid, (aliceShares * vault.getEpoch(epochId).priceRedeem) / WAD);
        (uint256 cash, uint256 pending,, uint256 reserved,,) = vault.accounting();
        assertGe(cash, pending + reserved);
    }

    /**
     * @dev T18/T21 residual, quantified and bounded. `instantRedeem` is the only
     *      backward-priced path, and a pending `commitTick` is public calldata, so
     *      its rate is known before it lands. A searcher who exits just ahead of a
     *      Tick that books a loss avoids the loss and pays only `instantFee`, so
     *      the front-run pays exactly when the loss can exceed the fee. The
     *      largest down-move one accepted Tick can carry is the down bucket's
     *      capacity (beyond it the Tick quarantines, which freezes instant exits),
     *      which gives the calibration rule:
     *
     *          instantFee >= downBucket.capacity  =>  no risk-free front-run
     *
     *      The first half shows the launch configuration (fee 0.1%, capacity
     *      0.2%) violating it; the second half shows the same front-run losing
     *      money once the fee covers the capacity.
     */
    function testInstantFeeMustCoverTheDownBucket() public {
        uint256 shares = vault.balanceOf(alice) / 200; // ~5k USDC: inside both caps
        uint256 loss = 1_200 * ONE; // 0.12% of nav: inside 0.2% capacity, above the 0.1% fee
        assertLt(vault.limits().instantFee, _defaultDown().capacity, "launch config is miscalibrated");

        _loss(hubSource, address(hubStrategy), loss);
        vm.prank(alice);
        uint256 out = vault.instantRedeem(shares, alice, alice, 0); // ahead of the commit
        _advance(60);
        _tick(); // books the loss
        uint256 held = (shares * _lastTick().rateBid) / WAD;
        assertGt(out, held, "fee < capacity: exiting ahead of the loss is profitable");
        assertLt(out - held, (shares * _defaultDown().capacity) / WAD, "gain bounded by the down capacity");

        // the fix: a fee at the capacity, and the same front-run, now loses
        IEpochVault.Limits memory l = vault.limits();
        l.instantFee = uint64(_defaultDown().capacity);
        vault.setLimits(l);
        accountant.setBuckets(_defaultUp(), _defaultDown()); // refill the down bucket
        vm.prank(alice);
        vault.transfer(bob, shares);

        _loss(hubSource, address(hubStrategy), loss);
        vm.prank(bob);
        uint256 out2 = vault.instantRedeem(shares, bob, bob, 0);
        _advance(60);
        _tick();
        assertLe(out2, (shares * _lastTick().rateBid) / WAD, "fee >= capacity: the front-run does not pay");
    }
}
