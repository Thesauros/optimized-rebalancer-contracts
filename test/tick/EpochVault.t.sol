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

    function testCancelOnlyBeforeCutoff() public {
        uint256 id = _requestDeposit(bob, 10_000 * ONE);
        vm.prank(attacker);
        vm.expectRevert(IEpochVault.NotRequestOwner.selector);
        vault.cancel(id);

        uint256 id2 = _requestDeposit(carol, 10_000 * ONE);
        vm.prank(carol);
        vault.cancel(id2);
        assertEq(usdc.balanceOf(carol), 10_000 * ONE, "refunded");

        _advance(1 hours);
        _tick();
        vault.closeEpoch();
        vm.prank(bob);
        vm.expectRevert(IEpochVault.RequestNotCancellable.selector);
        vault.cancel(id);
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
