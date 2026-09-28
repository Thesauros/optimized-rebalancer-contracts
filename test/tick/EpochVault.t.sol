// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IEpochVault} from "../../contracts/tick/interfaces/IEpochVault.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";

contract EpochVaultTest is TickFixture {
    uint256 internal aliceShares;

    function setUp() public override {
        super.setUp();
        aliceShares = _seedSystem(1_000_000 * ONE, 900_000 * ONE);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function testDepositMintsAtClearingOfferRate() public {
        uint256 id = _requestDeposit(bob, 10_000 * ONE);
        assertEq(vault.balanceOf(bob), 0, "no shares before clearing");

        _yield(hubSource, address(hubStrategy), 900 * ONE); // +0.09%
        uint64 epochId = _cycle();

        IEpochVault.Epoch memory e = vault.getEpoch(epochId);
        ITickAccountant.Tick memory t = accountant.getTick(e.depositTickId);
        assertGe(t.referenceTime, e.closedAt, "forward priced: tick observed after cutoff");
        assertEq(e.rateOffer, t.rateOffer);

        uint256 shares = vault.claim(id);
        assertEq(shares, (10_000 * ONE * WAD) / t.rateOffer, "shares = assets / offer");
        assertEq(vault.balanceOf(bob), shares);
    }

    function testPendingDepositIsNotNav() public {
        _requestDeposit(bob, 500_000 * ONE);
        _advance(60);
        uint64 id = _tick();
        ITickAccountant.Tick memory t = accountant.getTick(id);
        assertApproxEqAbs(t.rateBid, WAD, 2, "pending cash neither dilutes nor accretes");
    }

    /**
     * @dev Cancellation rules around the cutoff. A deposit stays cancellable
     *      until its epoch is cleared, because pending deposits are excluded from
     *      NAV, so the refund is NAV-neutral and cannot be used to leave at a
     *      pre-loss price. A redemption is never cancellable past the cutoff:
     *      its price is only fixed at clearing, so a late cancel would hand the
     *      holder a free option on the epoch's yield at the remaining holders'
     *      cost. Without the deposit half, a deposit caught in an epoch that
     *      closed while the accountant was frozen has no exit at all.
     */
    function testCancelRulesAroundCutoff() public {
        uint256 bobDeposit = _requestDeposit(bob, 10_000 * ONE);
        uint256 carolDeposit = _requestDeposit(carol, 10_000 * ONE);
        uint256 aliceRedeem = _requestRedeem(alice, 1_000 * ONE);
        uint64 epochId = vault.currentEpoch();

        vm.prank(attacker);
        vm.expectRevert(IEpochVault.NotRequestOwner.selector);
        vault.cancel(bobDeposit);

        _advance(1 hours);
        _tick();
        vault.closeEpoch();

        vm.prank(alice);
        vm.expectRevert(IEpochVault.RequestNotCancellable.selector);
        vault.cancel(aliceRedeem);

        (uint256 cash0, uint256 pending0,,,,) = vault.accounting();
        vm.prank(bob);
        vault.cancel(bobDeposit);
        assertEq(usdc.balanceOf(bob), 10_000 * ONE, "deposit refunded past the cutoff");
        (uint256 cash1, uint256 pending1,,,,) = vault.accounting();
        assertEq(cash0 - cash1, 10_000 * ONE, "cash left with the refund");
        assertEq(pending0 - pending1, 10_000 * ONE, "pending left with the refund");
        assertEq(cash0 - pending0, cash1 - pending1, "NAV-neutral");
        assertEq(vault.getEpoch(epochId).depositAssets, 10_000 * ONE, "epoch total shrank");

        // clearing still runs on the reduced total, and the cleared deposit is
        // now shares: it must be claimed, not cancelled
        _advance(60);
        _tick();
        _advance(1);
        vault.clearDeposits();
        assertEq(vault.getEpoch(epochId).sharesMinted, (10_000 * ONE * WAD) / vault.getEpoch(epochId).rateOffer);
        vm.prank(carol);
        vm.expectRevert(IEpochVault.RequestNotCancellable.selector);
        vault.cancel(carolDeposit);
        vm.prank(carol);
        assertGt(vault.claim(carolDeposit), 0, "cleared deposit is claimable");
    }

    /// @dev The same escape must work while settlement is impossible: an epoch
    ///      that closed under a guardian freeze cannot be cleared, so the refund
    ///      is the only way a depositor gets their assets back.
    function testCancelAfterCutoffWhileFrozen() public {
        uint256 id = _requestDeposit(bob, 10_000 * ONE);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();

        vm.prank(guardian);
        accountant.freeze();
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();

        vm.prank(bob);
        vault.cancel(id);
        assertEq(usdc.balanceOf(bob), 10_000 * ONE, "refunded while frozen");
    }

    function testClaimTwiceReverts() public {
        uint256 id = _requestDeposit(bob, 10_000 * ONE);
        _cycle();
        vault.claim(id);
        vm.expectRevert(IEpochVault.RequestNotClaimable.selector);
        vault.claim(id);
    }

    /*//////////////////////////////////////////////////////////////
                         REDEMPTION PRICING
    //////////////////////////////////////////////////////////////*/

    function testRedeemAfterGainPaysEpochOpenRate() public {
        uint256 openRate = vault.getEpoch(vault.currentEpoch()).openRateBid;
        uint256 shares = aliceShares / 10;
        uint256 id = _requestRedeem(alice, shares);
        _yield(hubSource, address(hubStrategy), 900 * ONE);
        uint64 epochId = _cycle();

        IEpochVault.Epoch memory e = vault.getEpoch(epochId);
        assertEq(e.priceRedeem, openRate, "gain during the queue stays with remaining holders");
        assertLt(e.priceRedeem, accountant.getTick(e.redeemTickId).rateBid);

        uint256 paid = vault.claim(id);
        assertEq(paid, (shares * openRate) / WAD);
    }

    /// @dev Front-running an unfavourable Tick: request before the loss is booked,
    ///      the loss is booked before clearing, the request bears it.
    function testRedeemBeforeNegativeTickBearsTheLoss() public {
        uint256 openRate = vault.getEpoch(vault.currentEpoch()).openRateBid;
        uint256 shares = aliceShares / 10;
        uint256 id = _requestRedeem(alice, shares);

        _loss(hubSource, address(hubStrategy), 900 * ONE); // -0.09%, within buckets
        uint64 epochId = _cycle();

        IEpochVault.Epoch memory e = vault.getEpoch(epochId);
        uint256 clearRate = accountant.getTick(e.redeemTickId).rateBid;
        assertLt(clearRate, openRate);
        assertEq(e.priceRedeem, clearRate, "min(open, clear) picks the post-loss price");
        assertEq(vault.claim(id), (shares * clearRate) / WAD);
    }

    function testClearingNeedsTickAfterCutoff() public {
        _requestDeposit(bob, 10_000 * ONE);
        _advance(1 hours);
        _tick();
        _advance(1);
        vault.closeEpoch();
        // latest tick predates the cutoff
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();
    }

    function testClearingRefusesStaleTick() public {
        _requestDeposit(bob, 10_000 * ONE);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        _advance(60);
        _tick();
        _advance(1 hours + 1); // beyond maxClearingDelay
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();
    }

    function testClearingRefusedWhileFrozen() public {
        _requestDeposit(bob, 10_000 * ONE);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        _advance(60);
        _tick();
        vm.prank(guardian);
        accountant.freeze();
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();

        // an empty side uses no price, so it clears even while frozen
        vault.clearRedeems();
        assertTrue(vault.getEpoch(vault.currentEpoch() - 1).redeemsCleared);
        assertEq(vault.getEpoch(vault.currentEpoch() - 1).assetsOwed, 0);
    }

    /// @dev A Tick that moved down beyond the deposit threshold settles exits
    ///      (under-paying is the safe side) but not entries.
    function testDownFlagBlocksDepositClearingNotRedeems() public {
        _requestDeposit(bob, 10_000 * ONE);
        _requestRedeem(alice, aliceShares / 10);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        _loss(hubSource, address(hubStrategy), 1_500 * ONE); // -0.15%
        _advance(60);
        uint64 id = _tick();
        assertTrue(accountant.getTick(id).flags & accountant.FLAG_DOWN_BEYOND_DEPOSIT_LIMIT() != 0);

        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.clearDeposits();
        vault.clearRedeems();

        // a later clean tick clears the carried deposits
        _advance(60);
        _tick();
        vault.clearDeposits();
        (uint64 nextDeposit,,) = vault.cursors();
        assertEq(nextDeposit, vault.currentEpoch());
    }

    /*//////////////////////////////////////////////////////////////
                          FUNDING AND LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function testRedeemWaitsForLiquidityThenFundsFifo() public {
        // vault holds ~100k cash; alice redeems ~50% of nav
        uint256 id = _requestRedeem(alice, aliceShares / 2);
        uint64 epochId = _cycle();
        assertFalse(vault.getEpoch(epochId).funded, "not enough free cash");
        vm.expectRevert(IEpochVault.RequestNotClaimable.selector);
        vault.claim(id);

        // executor recalls from the strategy; returning cash funds the epoch
        vm.startPrank(executor);
        hubAgent.deallocate(500_000 * ONE);
        hubAgent.returnToVault(500_000 * ONE);
        vm.stopPrank();
        assertTrue(vault.getEpoch(epochId).funded);
        assertGt(vault.claim(id), 0);
    }

    function testPushToAgentNeverTakesOwedCash() public {
        _requestRedeem(alice, aliceShares / 2);
        _cycle(); // cleared, unfunded
        (uint256 cash,,,,,) = vault.accounting();
        assertGt(cash, 0);
        vm.prank(executor);
        vm.expectRevert(IEpochVault.InsufficientFreeCash.selector);
        vault.pushToAgent(1);
    }

    function testPushRespectsMinimumBuffer() public {
        IEpochVault.Limits memory l = _defaultLimits();
        l.minimumBuffer = uint128(95_000 * ONE);
        vault.setLimits(l);
        uint256 free = vault.freeCash();
        vm.prank(executor);
        vm.expectRevert(IEpochVault.InsufficientFreeCash.selector);
        vault.pushToAgent(free - 94_000 * ONE);
        vm.prank(executor);
        vault.pushToAgent(free - 95_000 * ONE);
    }

    /*//////////////////////////////////////////////////////////////
                              INSTANT EXIT
    //////////////////////////////////////////////////////////////*/

    function testInstantRedeemAtBidMinusFee() public {
        _advance(60);
        _tick();
        ITickAccountant.Tick memory t = _lastTick();
        uint256 shares = 1_000 * ONE;
        vm.prank(alice);
        uint256 assets = vault.instantRedeem(shares, alice, alice, 0);
        uint256 price = (uint256(t.rateBid) * (WAD - 0.001e18)) / WAD;
        assertEq(assets, (shares * price) / WAD);
    }

    function testInstantLimitsPerCallAndPerDay() public {
        _advance(60);
        _tick();
        vm.prank(alice);
        vm.expectRevert(IEpochVault.LimitExceeded.selector);
        vault.instantRedeem(10_100 * ONE, alice, alice, 0);

        // 5 x ~9,990 fits in the 50k day, the 6th does not
        for (uint256 i; i < 5; i++) {
            vm.prank(alice);
            vault.instantRedeem(10_000 * ONE, alice, alice, 0);
        }
        vm.prank(alice);
        vm.expectRevert(IEpochVault.LimitExceeded.selector);
        vault.instantRedeem(1_000 * ONE, alice, alice, 0);

        // refills over time
        _advance(1 days);
        _tick();
        vm.prank(alice);
        vault.instantRedeem(10_000 * ONE, alice, alice, 0);
    }

    function testInstantRequiresFreshUnfrozenTick() public {
        _advance(2 hours + 1);
        vm.prank(alice);
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.instantRedeem(1_000 * ONE, alice, alice, 0);

        _tick();
        vm.prank(guardian);
        accountant.freeze();
        vm.prank(alice);
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vault.instantRedeem(1_000 * ONE, alice, alice, 0);
    }

    function testInstantCannotJumpTheQueue() public {
        _requestRedeem(alice, aliceShares / 2);
        _cycle(); // ~500k owed, ~100k cash: nothing available
        vm.prank(alice);
        vm.expectRevert(IEpochVault.InsufficientFreeCash.selector);
        vault.instantRedeem(1_000 * ONE, alice, alice, 0);
    }

    function testInstantSlippageGuard() public {
        _advance(60);
        _tick();
        vm.prank(alice);
        vm.expectRevert(IEpochVault.SlippageExceeded.selector);
        vault.instantRedeem(1_000 * ONE, alice, alice, 1_000 * ONE);
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE DOMAINS
    //////////////////////////////////////////////////////////////*/

    function testGuardianPausesAdminUnpauses() public {
        uint8 d = vault.DOMAIN_DEPOSIT_REQUEST();
        vm.prank(guardian);
        vault.pause(d);
        usdc.mint(bob, ONE * 10);
        vm.startPrank(bob);
        usdc.approve(address(vault), ONE * 10);
        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, d));
        vault.requestDeposit(ONE * 10, bob);
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.unpause(d);
        vm.prank(admin);
        vault.unpause(d);
    }

    /**
     * @dev Invariant 14, all six domains: each pause really blocks the operation
     *      it names, asserted against a live queue rather than an empty one, so a
     *      `NothingToClear` revert cannot masquerade as the pause.
     */
    function testEveryPauseDomainBlocksItsOwnOperation() public {
        // read the domain ids up front: a view call inside `expectRevert`'s
        // argument list would consume the prank that follows it
        uint8 dDeposit = vault.DOMAIN_DEPOSIT_REQUEST();
        uint8 dRedeem = vault.DOMAIN_REDEEM_REQUEST();
        uint8 dDepositClear = vault.DOMAIN_DEPOSIT_CLEARING();
        uint8 dRedeemClear = vault.DOMAIN_REDEEM_CLEARING();
        uint8 dInstant = vault.DOMAIN_INSTANT_EXIT();
        uint8 dAllocate = vault.DOMAIN_ALLOCATE();

        uint256 depositId = _requestDeposit(bob, 10_000 * ONE);
        _requestRedeem(alice, 1_000 * ONE);
        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        _advance(60);
        _tick();
        _advance(1);

        vm.startPrank(guardian);
        for (uint8 d; d < 6; d++) vault.pause(d);
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dDeposit));
        vault.requestDeposit(10_000 * ONE, carol);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dRedeem));
        vault.requestRedeem(1, carol, carol);

        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dDepositClear));
        vault.clearDeposits();

        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dRedeemClear));
        vault.clearRedeems();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dInstant));
        vault.instantRedeem(1_000 * ONE, alice, alice, 0);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IEpochVault.DomainPaused.selector, dAllocate));
        vault.pushToAgent(ONE);

        vm.startPrank(admin);
        for (uint8 d; d < 6; d++) vault.unpause(d);
        vm.stopPrank();
        vault.clearDeposits();
        vault.clearRedeems();
        assertGt(vault.claim(depositId), 0, "the queue resumes exactly where it stopped");
    }

    /// @dev Invariant 14: pausing new risk leaves owed exits payable.
    function testFundedClaimsAndCancelsSurviveEveryPause() public {
        uint256 redeemId = _requestRedeem(alice, 1_000 * ONE);
        _cycle();
        uint256 depositId = _requestDeposit(bob, 10_000 * ONE);

        vm.startPrank(guardian);
        for (uint8 d; d < 6; d++) vault.pause(d);
        accountant.freeze();
        vm.stopPrank();

        assertGt(vault.claim(redeemId), 0, "funded exit still payable");
        vm.prank(bob);
        vault.cancel(depositId);
        assertEq(usdc.balanceOf(bob), 10_000 * ONE, "cancel still works");
    }
}
