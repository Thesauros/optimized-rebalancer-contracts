// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RebalancerBase} from "../invariant/RebalancerBase.t.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MeshNode} from "../../contracts/crosschain/MeshNode.sol";
import {MeshProvider} from "../../contracts/crosschain/MeshProvider.sol";
import {IMeshNode} from "../../contracts/crosschain/interfaces/IMeshNode.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMeshBridgeAdapter} from "./MockMeshBridgeAdapter.sol";

contract MeshTest is RebalancerBase {
    MeshNode internal node;
    MeshProvider internal mesh;
    MockMeshBridgeAdapter internal bridge;
    address internal keeper = makeAddr("mesh keeper");
    address internal guardian = makeAddr("mesh guardian");
    address internal remote = makeAddr("remote custody");
    bytes32 internal constant ROUTE = keccak256("base-arbitrum-principal");
    uint256 internal constant REMOTE_CHAIN = 42161;

    function setUp() public override {
        super.setUp();
        node = new MeshNode(address(asset), address(this), keeper, guardian);
        mesh = new MeshProvider(node);
        bridge = new MockMeshBridgeAdapter();
        node.configureVault(address(vault), true, 2_000, 8_000);
        node.addRoute(ROUTE, address(bridge), REMOTE_CHAIN, _peer(), MILLION, 100);
        _attach(vault);
        _executeDeposit(vault, THOUSAND, alice);
        _rebalance(vault, 500 * ONE, providerA, mesh);
        vm.prank(remote);
        asset.approve(address(bridge), type(uint256).max);
    }

    function _peer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(remote)));
    }

    function _attach(Rebalancer v) internal {
        IProvider[] memory providers = new IProvider[](4);
        providers[0] = providerA;
        providers[1] = providerB;
        providers[2] = providerC;
        providers[3] = mesh;
        v.setProviders(providers);
        v.grantRole(v.EXECUTOR_ROLE(), keeper);
    }

    function _rebalance(Rebalancer v, uint256 amount, IProvider from, IProvider to) internal {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = amount;
        sources[0] = from;
        destinations[0] = to;
        vm.prank(keeper);
        v.rebalance(amounts, sources, destinations);
    }

    function _send(uint256 amount) internal returns (bytes32) {
        vm.prank(keeper);
        return node.bridgeOut(address(vault), ROUTE, amount, amount);
    }

    function _assertAccounting() internal view {
        assertEq(node.totalAssets(), node.totalLocalAssets() + node.totalRemoteAssets());
        assertGe(asset.balanceOf(address(node)), node.totalLocalAssets());
        assertEq(node.balanceOf(address(vault)), node.localAssets(address(vault)) + node.remoteAssets(address(vault)));
        assertEq(
            vault.totalAssets(),
            sourceA.balanceOf(address(vault)) + sourceB.balanceOf(address(vault)) + sourceC.balanceOf(address(vault))
                + node.balanceOf(address(vault))
        );
    }

    function testDelayedRoundTripPreservesNAV() public {
        uint256 nav = vault.totalAssets();
        bytes32 id = _send(300 * ONE);
        assertEq(node.localAssets(address(vault)), 200 * ONE);
        assertEq(node.remoteAssets(address(vault)), 300 * ONE);
        assertEq(asset.balanceOf(remote), 0);
        assertEq(vault.totalAssets(), nav);
        _assertAccounting();
        vm.warp(block.timestamp + 1 hours);
        bridge.deliverOutbound(id);
        assertEq(asset.balanceOf(remote), 300 * ONE);
        assertEq(vault.totalAssets(), nav);
        vm.warp(block.timestamp + 1 days);
        bridge.deliverReturn(id, 300 * ONE);
        assertEq(node.localAssets(address(vault)), 500 * ONE);
        assertEq(node.remoteAssets(address(vault)), 0);
        assertEq(node.pendingPrincipal(address(vault)), 0);
        assertEq(vault.totalAssets(), nav);
        assertEq(asset.allowance(address(node), address(bridge)), 0);
        _rebalance(vault, 500 * ONE, mesh, providerA);
        _executeWithdraw(vault, THOUSAND, alice);
        _assertAccounting();
    }

    function testBridgeFeeAndReturnLossAreRealizedOnce() public {
        bridge.setFee(100);
        vm.prank(keeper);
        bytes32 id = node.bridgeOut(address(vault), ROUTE, 300 * ONE, 297 * ONE);
        assertEq(node.balanceOf(address(vault)), 497 * ONE);
        assertEq(vault.totalAssets(), 998 * ONE);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 290 * ONE);
        assertEq(node.balanceOf(address(vault)), 490 * ONE);
        assertEq(vault.totalAssets(), 991 * ONE);
        assertEq(asset.balanceOf(address(bridge)), 3 * ONE);
        _assertAccounting();
    }

    function testDepositAndWithdrawWhileTransferIsPending() public {
        _send(300 * ONE);
        _executeDeposit(vault, 100 * ONE, bob);
        _executeWithdraw(vault, 650 * ONE, alice);
        assertEq(node.localAssets(address(vault)), 151 * ONE);
        assertEq(node.remoteAssets(address(vault)), 300 * ONE);
        _assertAccounting();
    }

    function testInsufficientLiquidityRollsBackUserSharesAndAllProviders() public {
        _send(300 * ONE);
        uint256 shares = vault.balanceOf(alice);
        vm.expectRevert(IRebalancer.InsufficientLiquidity.selector);
        vm.prank(alice);
        vault.withdraw(800 * ONE, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(sourceA.balanceOf(address(vault)), 501 * ONE);
        assertEq(node.localAssets(address(vault)), 200 * ONE);
        _assertAccounting();
    }

    function testShortRebalanceCannotSpendUnaccountedVaultTokens() public {
        _send(300 * ONE);
        asset.mint(address(vault), 200 * ONE);
        vm.expectRevert(MeshNode.InsufficientLiquidity.selector);
        _rebalance(vault, 300 * ONE, mesh, providerA);
        assertEq(asset.balanceOf(address(vault)), 200 * ONE);
        assertEq(sourceA.balanceOf(address(vault)), 501 * ONE);
        assertEq(node.localAssets(address(vault)), 200 * ONE);
    }

    function testVaultSkipsMeshShortageAndUsesNextProvider() public {
        _send(300 * ONE);
        IProvider[] memory providers = new IProvider[](2);
        providers[0] = mesh;
        providers[1] = providerA;
        vault.setProviders(providers);
        _executeWithdraw(vault, 400 * ONE, alice);
        assertEq(node.localAssets(address(vault)), 200 * ONE);
        assertEq(sourceA.balanceOf(address(vault)), 101 * ONE);
    }

    function testDonationsDoNotInflateNAVOrPreventDeposits() public {
        asset.mint(address(node), 5_000 * ONE);
        assertEq(node.balanceOf(address(vault)), 500 * ONE);
        _rebalance(vault, 100 * ONE, providerA, mesh);
        assertEq(node.balanceOf(address(vault)), 600 * ONE);
        assertEq(vault.totalAssets(), 1_001 * ONE);
        _rebalance(vault, 600 * ONE, mesh, providerA);
        assertEq(asset.balanceOf(address(node)), 5_000 * ONE);
        assertEq(node.totalAssets(), 0);
    }

    function testTwoVaultsHaveIsolatedPrincipalFeesAndLiquidity() public {
        Rebalancer other = _deployVault();
        _initializeVault(other, _defaultProviders());
        _attach(other);
        node.configureVault(address(other), true, 2_000, 8_000);
        _executeDeposit(other, 200 * ONE, bob);
        _rebalance(other, 200 * ONE, providerA, mesh);
        bridge.setFee(100);
        vm.prank(keeper);
        bytes32 id = node.bridgeOut(address(vault), ROUTE, 300 * ONE, 297 * ONE);
        assertEq(node.balanceOf(address(other)), 200 * ONE);
        assertEq(other.totalAssets(), 201 * ONE);
        node.writeDown(id, 100 * ONE, keccak256("loss"));
        assertEq(other.totalAssets(), 201 * ONE);
        vm.expectRevert(MeshNode.InsufficientLiquidity.selector);
        _rebalance(vault, 300 * ONE, mesh, providerA);
        _rebalance(other, 200 * ONE, mesh, providerA);
        assertEq(node.totalAssets(), node.balanceOf(address(vault)));
        _assertAccounting();
    }

    function testGuardianPausePreservesReturnAndExit() public {
        bytes32 id = _send(300 * ONE);
        vm.prank(guardian);
        node.setPaused(true);
        vm.expectRevert(MeshNode.Paused.selector);
        _send(ONE);
        vm.expectRevert(MeshNode.Paused.selector);
        _rebalance(vault, ONE, providerA, mesh);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        vm.prank(guardian);
        node.setPaused(false);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        _executeWithdraw(vault, THOUSAND, alice);
        node.setPaused(false);
        assertFalse(node.paused());
    }

    function testDisabledVaultAndRoutePreserveReturnsAndExits() public {
        bytes32 id = _send(300 * ONE);
        node.configureVault(address(vault), false, 2_000, 8_000);
        node.configureRoute(ROUTE, false, MILLION, 100);
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        _send(ONE);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        _rebalance(vault, ONE, providerA, mesh);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        _rebalance(vault, 500 * ONE, mesh, providerA);
        _assertAccounting();
    }

    function testUnauthorizedAccess() public {
        vm.startPrank(alice);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.configureVault(address(vault), true, 0, 10_000);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.setRoles(alice, alice);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.setPaused(true);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.configureRoute(ROUTE, true, MILLION, 100);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.addRoute(keccak256("bad"), address(bridge), REMOTE_CHAIN, _peer(), MILLION, 100);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.bridgeOut(address(vault), ROUTE, ONE, ONE);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.depositFromVault(ONE);
        vm.expectRevert(MeshNode.InsufficientLiquidity.selector);
        node.withdrawToVault(ONE);
        vm.stopPrank();
        _assertAccounting();
    }

    function testProviderDirectCallsCannotMoveVaultFunds() public {
        vm.expectRevert(MeshProvider.InvalidContext.selector);
        mesh.deposit(ONE, vault);
        vm.expectRevert(MeshProvider.InvalidContext.selector);
        mesh.withdraw(ONE, vault);
        assertEq(asset.allowance(address(vault), address(node)), type(uint256).max);
        assertEq(mesh.getDepositRate(vault), 0);
        assertEq(mesh.getSource(address(0), address(0), address(0)), address(node));
        _assertAccounting();
    }

    function testReserveAndRemoteExposureLimits() public {
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(400 * ONE + 1);
        node.configureVault(address(vault), true, 0, 5_000);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(250 * ONE + 1);
        node.configureVault(address(vault), true, 5_000, 10_000);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(250 * ONE + 1);
        _send(250 * ONE);
        _assertAccounting();
    }

    function testRouteCapacityAndFeeMinimum() public {
        node.configureRoute(ROUTE, true, 200 * ONE, 100);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(200 * ONE + 1);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        vm.prank(keeper);
        node.bridgeOut(address(vault), ROUTE, 100 * ONE, 98 * ONE);
        assertEq(node.nonce(), 0);
        assertEq(asset.balanceOf(address(bridge)), 0);
        _assertAccounting();
    }

    function testRouteIdentityCannotBeReplacedWhilePending() public {
        _send(300 * ONE);
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        node.addRoute(ROUTE, address(bridge), REMOTE_CHAIN, bytes32(uint256(1)), MILLION, 100);
    }

    function testQuoteAndDebitFailuresRollBackAccountingAndApprovals() public {
        bridge.setShortDebit(true);
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        _send(300 * ONE);
        bridge.setShortDebit(false);
        bridge.setOverQuote(true);
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        _send(300 * ONE);
        bridge.setOverQuote(false);
        bridge.setBelowMinimum(true);
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        _send(300 * ONE);
        bridge.setBelowMinimum(false);
        bridge.setFailSend(true);
        vm.expectRevert("bridge unavailable");
        _send(300 * ONE);
        assertEq(node.nonce(), 0);
        assertEq(asset.balanceOf(address(bridge)), 0);
        assertEq(asset.allowance(address(node), address(bridge)), 0);
        assertEq(node.balanceOf(address(vault)), 500 * ONE);
        _assertAccounting();
    }

    function testNativeFeeComesOnlyFromExecutor() public {
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        node.bridgeOut{value: 0.01 ether}(address(vault), ROUTE, 100 * ONE, 100 * ONE);
        assertEq(bridge.nativeFeeReceived(), 0.01 ether);
        assertEq(address(node).balance, 0);
        assertEq(node.balanceOf(address(vault)), 500 * ONE);
    }

    function testReturnRequiresCorrectAdapterChainPeerAndFunds() public {
        bytes32 id = _send(300 * ONE);
        vm.expectRevert(MeshNode.InvalidTransfer.selector);
        node.receiveReturn(keccak256("unknown"), REMOTE_CHAIN, _peer(), ONE);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.receiveReturn(id, REMOTE_CHAIN, _peer(), ONE);
        vm.startPrank(address(bridge));
        vm.expectRevert(MeshNode.InvalidPeer.selector);
        node.receiveReturn(id, REMOTE_CHAIN + 1, _peer(), ONE);
        vm.expectRevert(MeshNode.InvalidPeer.selector);
        node.receiveReturn(id, REMOTE_CHAIN, bytes32(uint256(1)), ONE);
        vm.expectRevert(MeshNode.InvalidAmount.selector);
        node.receiveReturn(id, REMOTE_CHAIN, _peer(), 301 * ONE);
        vm.expectRevert(); // No allowance: a message alone cannot fund the local ledger.
        node.receiveReturn(id, REMOTE_CHAIN, _peer(), 300 * ONE);
        vm.stopPrank();
        assertEq(node.remoteAssets(address(vault)), 300 * ONE);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        _assertAccounting();
    }

    function testReplayAndDuplicateOutboundAreRejected() public {
        bytes32 id = _send(300 * ONE);
        bridge.deliverOutbound(id);
        vm.expectRevert("invalid outbound");
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        vm.expectRevert(MeshNode.InvalidTransfer.selector);
        vm.prank(address(bridge));
        node.receiveReturn(id, REMOTE_CHAIN, _peer(), 0);
        assertEq(node.localAssets(address(vault)), 500 * ONE);
    }

    function testFullLossSettlement() public {
        bytes32 id = _send(300 * ONE);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 0);
        assertEq(node.totalAssets(), 200 * ONE);
        assertEq(node.remoteAssets(address(vault)), 0);
        assertEq(node.pendingPrincipal(address(vault)), 0);
        _assertAccounting();
    }

    function testWriteDownKeepsExposureAndPermitsLateRecovery() public {
        bytes32 id = _send(300 * ONE);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        vm.prank(keeper);
        node.writeDown(id, 100 * ONE, keccak256("loss"));
        node.writeDown(id, 100 * ONE, keccak256("loss"));
        assertEq(node.balanceOf(address(vault)), 400 * ONE);
        assertEq(node.pendingPrincipal(address(vault)), 300 * ONE);
        (,,,, uint256 pending,,) = node.routes(ROUTE);
        assertEq(pending, 300 * ONE);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(21 * ONE); // nominal exposure, not the reduced book value
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 250 * ONE);
        assertEq(node.balanceOf(address(vault)), 450 * ONE);
        assertEq(node.pendingPrincipal(address(vault)), 0);
        vm.expectRevert(MeshNode.InvalidTransfer.selector);
        node.writeDown(id, ONE, keccak256("duplicate"));
        _assertAccounting();
    }

    function testWriteDownCannotReopenNominalRouteCapacity() public {
        node.configureRoute(ROUTE, true, 300 * ONE, 100);
        bytes32 id = _send(300 * ONE);
        node.writeDown(id, 300 * ONE, keccak256("bridge stalled"));
        node.configureVault(address(vault), true, 0, 10_000);
        vm.expectRevert(MeshNode.LimitExceeded.selector);
        _send(ONE);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        assertEq(node.balanceOf(address(vault)), 500 * ONE);
    }

    function testReentrantSendCannotSettleBeforeSendCompletes() public {
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(node), uint256(1)));
        bridge.setSendCallback(abi.encodeCall(node.receiveReturn, (expectedId, REMOTE_CHAIN, _peer(), 0)));
        bytes32 id = _send(300 * ONE);
        assertEq(id, expectedId);
        assertFalse(bridge.callbackSucceeded());
        assertEq(node.remoteAssets(address(vault)), 300 * ONE);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, 300 * ONE);
        _assertAccounting();
    }

    function testGovernanceUsesRealTimelockDelay() public {
        Timelock timelock = new Timelock(address(this), 1 hours);
        MeshNode governed = new MeshNode(address(asset), address(timelock), keeper, guardian);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        governed.configureVault(address(vault), true, 2_000, 8_000);
        uint256 eta = block.timestamp + 1 hours;
        bytes memory data = abi.encodeCall(governed.configureVault, (address(vault), true, 2_000, 8_000));
        timelock.queue(address(governed), 0, "", data, eta);
        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        timelock.execute(address(governed), 0, "", data, eta);
        vm.warp(eta);
        timelock.execute(address(governed), 0, "", data, eta);
        (bool enabled,,) = governed.vaults(address(vault));
        assertTrue(enabled);
    }

    function testInvalidConfigurationAndAmounts() public {
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        new MeshNode(address(asset), alice, keeper, guardian);
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        node.setRoles(address(0), guardian);
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        node.configureVault(address(vault), true, 10_001, 0);
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        node.addRoute(keccak256("local"), address(bridge), block.chainid, _peer(), MILLION, 100);
        vm.expectRevert(MeshNode.InvalidAmount.selector);
        _send(0);
        vm.expectRevert(MeshNode.InsufficientLiquidity.selector);
        _send(501 * ONE);
        bytes32 id = _send(300 * ONE);
        vm.expectRevert(MeshNode.InvalidAmount.selector);
        node.writeDown(id, 301 * ONE, keccak256("loss"));
        vm.expectRevert(MeshNode.InvalidAmount.selector);
        node.writeDown(id, ONE, bytes32(0));
    }

    function testFuzzConservation(uint256 sendAmount, uint256 recovery, uint16 fee) public {
        sendAmount = bound(sendAmount, ONE, 390 * ONE);
        fee = uint16(bound(fee, 0, 100));
        bridge.setFee(fee);
        uint256 credited = sendAmount - sendAmount * fee / 10_000;
        recovery = bound(recovery, 0, credited);
        vm.prank(keeper);
        bytes32 id = node.bridgeOut(address(vault), ROUTE, sendAmount, credited);
        assertEq(node.balanceOf(address(vault)), 500 * ONE - sendAmount + credited);
        bridge.deliverOutbound(id);
        bridge.deliverReturn(id, recovery);
        assertEq(node.totalAssets(), 500 * ONE - sendAmount + recovery);
        assertEq(node.totalRemoteAssets(), 0);
        assertEq(node.totalLocalAssets() + asset.balanceOf(remote) + asset.balanceOf(address(bridge)), 500 * ONE);
        _assertAccounting();
    }
}
