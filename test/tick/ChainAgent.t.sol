// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {ShortPullAdapter, ForgingAdapter, ReentrantAdapter} from "./mocks/MockBridge.sol";

contract ChainAgentTest is TickFixture {
    function setUp() public override {
        super.setUp();
        _seedSystem(1_000_000 * ONE, 0);
        vm.prank(executor);
        vault.pushToAgent(900_000 * ONE); // idle on the hub agent
        _advance(60);
        _tick();
    }

    /*//////////////////////////////////////////////////////////////
                    ROUTES: FIXED RECIPIENT AND LIMITS
    //////////////////////////////////////////////////////////////*/

    function testBridgeOutMovesExactAmountToTheWire() public {
        uint256 before = usdc.balanceOf(address(hubAgent));
        (bytes32 id,) = _bridgeHubToSpoke(100_000 * ONE, 100_000 * ONE);
        assertEq(before - usdc.balanceOf(address(hubAgent)), 100_000 * ONE);
        ChainAgent.Sent memory s = hubAgent.getSent(id);
        assertEq(s.amount, 100_000 * ONE);
        assertEq(s.dstChainId, SPOKE);
    }

    /// @dev Invariant 7: the executor has no parameter for a recipient, and an
    ///      unknown route id has no adapter.
    function testExecutorCannotChooseRecipientOrRoute() public {
        vm.prank(executor);
        vm.expectRevert(ChainAgent.RouteDisabled.selector);
        hubAgent.bridgeOut(keccak256("attacker-route"), 1_000 * ONE, 1_000 * ONE, bytes32(0));

        // adding a route is timelock-only
        vm.prank(executor);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        hubAgent.addRoute(keccak256("x"), address(hubAdapter), SPOKE, attacker, 0, 1, 1, 1);
        vm.prank(admin);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        hubAgent.addRoute(keccak256("x"), address(hubAdapter), SPOKE, attacker, 0, 1, 1, 1);
    }

    function testRouteEndpointsArePermanent() public {
        vm.expectRevert(ChainAgent.InvalidConfig.selector);
        hubAgent.addRoute(ROUTE_TO_SPOKE, address(hubAdapter), SPOKE, attacker, 0, 1, 1, 1);
        assertEq(hubAgent.getRoute(ROUTE_TO_SPOKE).dstAgent, address(spokeAgent));
    }

    function testMaxPerTransfer() public {
        hubAgent.configureRoute(ROUTE_TO_SPOKE, true, 50, uint128(50_000 * ONE), uint128(2_000_000 * ONE), 0);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.LimitExceeded.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 50_001 * ONE, 50_001 * ONE, bytes32(0));
    }

    /// @dev Invariant 8: volume over any window <= capacity + refill * window.
    function testRouteVolumeBucket() public {
        hubAgent.configureRoute(ROUTE_TO_SPOKE, true, 50, uint128(1_000_000 * ONE), uint128(150_000 * ONE), uint128(100_000 * ONE) / 1 days);
        _bridgeHubToSpoke(100_000 * ONE, 100_000 * ONE);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.LimitExceeded.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 60_000 * ONE, 60_000 * ONE, bytes32(0));

        _advance(12 hours); // +50k refill
        _tick(); // sends need a fresh tick on the hub
        vm.prank(executor);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 100_000 * ONE, 100_000 * ONE, bytes32(0));
    }

    function testMinReceiveFloorFromFeeCap() public {
        // maxFeeBps = 50 -> minReceive >= 99.5%
        vm.prank(executor);
        vm.expectRevert(ChainAgent.LimitExceeded.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 10_000 * ONE, 9_949 * ONE, bytes32(0));
        vm.prank(executor);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 10_000 * ONE, 9_950 * ONE, bytes32(0));
    }

    function testShortPullingAdapterIsRejected() public {
        ShortPullAdapter bad = new ShortPullAdapter(address(usdc), address(hubAgent), wire, HUB);
        hubAgent.addRoute(keccak256("bad"), address(bad), SPOKE, address(spokeAgent), 50, uint128(1e30), uint128(1e30), 0);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.UnexpectedTokenAmount.selector);
        hubAgent.bridgeOut(keccak256("bad"), 1_000 * ONE, 1_000 * ONE, bytes32(0));
    }

    function testGuardianCanDisableRouteInstantly() public {
        vm.prank(guardian);
        hubAgent.disableRoute(ROUTE_TO_SPOKE);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.RouteDisabled.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 1_000 * ONE, 1_000 * ONE, bytes32(0));
    }

    function testHubSendsHaltWhenAccountantFrozen() public {
        vm.prank(guardian);
        accountant.freeze();
        vm.prank(executor);
        vm.expectRevert(ChainAgent.SendsHalted.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 1_000 * ONE, 1_000 * ONE, bytes32(0));
    }

    function testHubSendsHaltOnInFlightLimitFlag() public {
        // 50% cap: put ~60% of nav in flight, then tick
        _bridgeHubToSpoke(600_000 * ONE, 600_000 * ONE);
        _advance(60);
        uint64 id = _tick();
        assertTrue(accountant.getTick(id).flags & accountant.FLAG_IN_FLIGHT_LIMIT() != 0);
        vm.prank(executor);
        vm.expectRevert(ChainAgent.SendsHalted.selector);
        hubAgent.bridgeOut(ROUTE_TO_SPOKE, 1_000 * ONE, 1_000 * ONE, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIPT
    //////////////////////////////////////////////////////////////*/

    function testReceiptIsMeasuredAndPermissionless() public {
        (bytes32 id, uint256 idx) = _bridgeHubToSpoke(100_000 * ONE, 100_000 * ONE);
        vm.chainId(SPOKE);
        vm.prank(attacker); // any relayer
        (bytes32 got, uint256 amount) = spokeAgent.receiveBridge(address(spokeAdapter), abi.encode(idx));
        vm.chainId(HUB);
        assertEq(got, id);
        assertEq(amount, 100_000 * ONE);
        assertEq(spokeAgent.getReceived(id).amount, 100_000 * ONE);
    }

    /// @dev amountReceived < amountSent: the shortfall is recorded, not assumed away.
    function testFeeChargingBridgeRecordsActualReceipt() public {
        wire.setFeeBps(3); // 0.03%
        (bytes32 id, uint256 idx) = _bridgeHubToSpoke(1_000_000 * ONE / 10, 99_700 * ONE);
        _deliverToSpoke(idx);
        assertEq(spokeAgent.getReceived(id).amount, 100_000 * ONE - 30 * ONE);
    }

    /// @dev Invariant 6: a transfer completes at most once.
    function testDuplicateDeliveryRejected() public {
        wire.setAllowRedelivery(true);
        (, uint256 idx) = _bridgeHubToSpoke(10_000 * ONE, 10_000 * ONE);
        usdc.mint(address(wire), 10_000 * ONE); // the bridge would really pay twice
        _deliverToSpoke(idx);
        vm.chainId(SPOKE);
        vm.expectRevert(ChainAgent.AlreadyReceived.selector);
        spokeAgent.receiveBridge(address(spokeAdapter), abi.encode(idx));
        vm.chainId(HUB);
    }

    function testForgedSourceIsRejected() public {
        vm.chainId(SPOKE);
        ForgingAdapter forger = new ForgingAdapter(address(usdc), address(spokeAgent), wire, SPOKE);
        vm.chainId(HUB);
        spokeAgent.setAdapter(address(forger), true);
        hubAdapter.setRemote(SPOKE, address(forger));
        (, uint256 idx) = _bridgeHubToSpoke(10_000 * ONE, 10_000 * ONE);

        forger.forge(keccak256("fake"), HUB, attacker); // not a configured peer
        vm.chainId(SPOKE);
        vm.expectRevert(ChainAgent.UnknownPeer.selector);
        spokeAgent.receiveBridge(address(forger), abi.encode(idx));
        vm.chainId(HUB);
    }

    function testUnknownAdapterRejected() public {
        vm.chainId(SPOKE);
        vm.expectRevert(ChainAgent.UnknownAdapter.selector);
        spokeAgent.receiveBridge(attacker, abi.encode(uint256(0)));
        vm.chainId(HUB);
    }

    function testReentrantAdapterCannotDoubleBook() public {
        vm.chainId(SPOKE);
        ReentrantAdapter re = new ReentrantAdapter(address(usdc), address(spokeAgent), wire, SPOKE);
        vm.chainId(HUB);
        spokeAgent.setAdapter(address(re), true);
        hubAdapter.setRemote(SPOKE, address(re));
        (, uint256 idx) = _bridgeHubToSpoke(10_000 * ONE, 10_000 * ONE);
        re.setReentry(abi.encode(idx));
        vm.chainId(SPOKE);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        spokeAgent.receiveBridge(address(re), abi.encode(idx));
        vm.chainId(HUB);
    }

    function testOnlyAgentCanFinalizeOnItsAdapter() public {
        (, uint256 idx) = _bridgeHubToSpoke(10_000 * ONE, 10_000 * ONE);
        vm.prank(attacker);
        vm.expectRevert("only agent");
        spokeAdapter.finalize(abi.encode(idx));
    }

    /*//////////////////////////////////////////////////////////////
                         WRITE-DOWN AND STRATEGY
    //////////////////////////////////////////////////////////////*/

    function testWriteDownIsAdminOnlyAndBounded() public {
        (bytes32 id,) = _bridgeHubToSpoke(10_000 * ONE, 10_000 * ONE);
        vm.prank(executor);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        hubAgent.writeDown(id, 1, "x");

        vm.startPrank(admin);
        vm.expectRevert(ChainAgent.InvalidInput.selector);
        hubAgent.writeDown(id, 10_001 * ONE, "too much");
        hubAgent.writeDown(id, 4_000 * ONE, "attestation delayed");
        vm.stopPrank();
        assertEq(hubAgent.getSent(id).writtenDown, 4_000 * ONE);
    }

    function testDeallocateNeverPaused() public {
        vm.prank(executor);
        hubAgent.allocate(100_000 * ONE);
        uint8 domain = hubAgent.DOMAIN_ALLOCATE();
        vm.prank(guardian);
        hubAgent.pause(domain);
        vm.prank(guardian);
        accountant.freeze();
        vm.prank(executor);
        hubAgent.deallocate(50_000 * ONE);
        vm.prank(executor);
        hubAgent.returnToVault(50_000 * ONE);
    }

    function testStrategyReplaceableOnlyWhenEmpty() public {
        vm.prank(executor);
        hubAgent.allocate(10_000 * ONE);
        vm.expectRevert(ChainAgent.StrategyNotEmpty.selector);
        hubAgent.setStrategy(address(spokeStrategy));
    }
}
