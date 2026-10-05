// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RebalancerBase} from "../invariant/RebalancerBase.t.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {MeshNode} from "../../contracts/crosschain/MeshNode.sol";
import {MeshProvider} from "../../contracts/crosschain/MeshProvider.sol";
import {MeshCustodian} from "../../contracts/crosschain/MeshCustodian.sol";
import {ICustodianProvider} from "../../contracts/crosschain/interfaces/ICustodianProvider.sol";
import {IMeshBridgeAdapter} from "../../contracts/crosschain/interfaces/IMeshBridgeAdapter.sol";
import {IMeshNode} from "../../contracts/crosschain/interfaces/IMeshNode.sol";
import {MockCustodianProvider} from "./MockCustodianProvider.sol";

/// @dev Bidirectional mock bridge. Auto-detects direction: first `send` per transferId = outbound,
///      second `send` (after delivery) = return. Stores destChainId so return has correct sourceChainId.
contract DualMeshBridgeAdapter is IMeshBridgeAdapter {
    using SafeERC20 for IERC20;

    struct OutboundMessage {
        address sourceNode;
        address destCustodian;
        address asset;
        uint256 amount;
        uint256 destChainId;
        bool delivered;
    }

    struct ReturnMsg {
        address destNode;
        address asset;
        uint256 amount;
        bytes32 transferId;
        uint256 sourceChainId;
        bytes32 sourcePeer;
        bool delivered;
    }

    uint256 public feeBps;
    mapping(bytes32 => OutboundMessage) public outbound;
    mapping(bytes32 => ReturnMsg) public returnMsgs;

    function setFee(uint256 value) external {
        feeBps = value;
    }

    function send(
        bytes32 transferId,
        address asset,
        uint256 amount,
        uint256 destinationChainId,
        bytes32 destinationPeer,
        uint256
    ) external payable returns (uint256 credited) {
        if (outbound[transferId].delivered) {
            // Return direction: no fee (simulates same bridge message)
            credited = amount;
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            returnMsgs[transferId] = ReturnMsg({
                destNode: address(uint160(uint256(destinationPeer))),
                asset: asset,
                amount: credited,
                transferId: transferId,
                sourceChainId: outbound[transferId].destChainId,
                sourcePeer: bytes32(uint256(uint160(msg.sender))),
                delivered: false
            });
        } else {
            // Outbound direction: fee applies
            credited = amount - amount * feeBps / 10_000;
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (feeBps > 0) {
                IERC20(asset).transfer(address(0xdead), amount - credited);
            }
            outbound[transferId] = OutboundMessage({
                sourceNode: msg.sender,
                destCustodian: address(uint160(uint256(destinationPeer))),
                asset: asset,
                amount: credited,
                destChainId: destinationChainId,
                delivered: false
            });
        }
    }

    function deliverToCustodian(bytes32 transferId) external {
        OutboundMessage storage m = outbound[transferId];
        require(m.sourceNode != address(0) && !m.delivered, "invalid outbound");
        m.delivered = true;
        IERC20(m.asset).forceApprove(m.destCustodian, m.amount);
        MeshCustodian(payable(m.destCustodian)).onBridgeIn(
            uint64(block.chainid), m.amount, transferId
        );
        IERC20(m.asset).forceApprove(m.destCustodian, 0);
    }

    function deliverReturn(bytes32 transferId) external {
        ReturnMsg storage m = returnMsgs[transferId];
        require(m.destNode != address(0) && !m.delivered, "invalid return");
        m.delivered = true;
        IERC20(m.asset).forceApprove(m.destNode, m.amount);
        IMeshNode(m.destNode).receiveReturn(m.transferId, m.sourceChainId, m.sourcePeer, m.amount);
        IERC20(m.asset).forceApprove(m.destNode, 0);
    }
}

/// @title MeshFullCycleTest
/// @notice End-to-end: Vault -> MeshProvider -> MeshNode -> Bridge -> MeshCustodian -> Provider -> Bridge -> MeshNode -> Vault
contract MeshFullCycleTest is RebalancerBase {
    using SafeERC20 for IERC20;

    MeshNode internal srcNode;
    MeshProvider internal meshProvider;
    MeshCustodian internal dstCustodian;
    DualMeshBridgeAdapter internal bridge;
    MockCustodianProvider internal dstProvider;

    address internal keeper = makeAddr("cycle keeper");
    address internal guardian = makeAddr("cycle guardian");
    address internal custodianExecutor = makeAddr("custodian executor");
    address internal custodianGuardian = makeAddr("custodian guardian");

    bytes32 internal constant ROUTE = keccak256("base-arb-cycle");
    uint256 internal constant DST_CHAIN = 42161;

    function setUp() public override {
        super.setUp();

        srcNode = new MeshNode(address(asset), address(this), keeper, guardian);
        meshProvider = new MeshProvider(srcNode);

        dstCustodian = new MeshCustodian(address(asset), address(this), custodianExecutor, custodianGuardian);
        dstProvider = new MockCustodianProvider(address(asset));

        bridge = new DualMeshBridgeAdapter();

        srcNode.configureVault(address(vault), true, 2_000, 8_000);
        srcNode.addRoute(ROUTE, address(bridge), DST_CHAIN, _custodianPeer(), MILLION, 100);

        dstCustodian.trustAdapter(address(bridge), true);
        dstCustodian.allowProvider(address(dstProvider), true);

        IProvider[] memory providers = new IProvider[](4);
        providers[0] = providerA;
        providers[1] = providerB;
        providers[2] = providerC;
        providers[3] = meshProvider;
        vault.setProviders(providers);
        vault.grantRole(vault.EXECUTOR_ROLE(), keeper);

        _executeDeposit(vault, THOUSAND, alice);
    }

    function _custodianPeer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(dstCustodian))));
    }

    function _rebalance(IRebalancer v, uint256 amount, IProvider from, IProvider to) internal {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = amount;
        sources[0] = from;
        destinations[0] = to;
        vm.prank(keeper);
        v.rebalance(amounts, sources, destinations);
    }

    /// @dev Deliver outbound + custodian bridgeBack + deliver return. Assumes not yet delivered.
    function _fullReturn(bytes32 transferId, uint256 returnAmount) internal {
        bridge.deliverToCustodian(transferId);
        vm.prank(custodianExecutor);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId,
            returnAmount,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            returnAmount
        );
        bridge.deliverReturn(transferId);
    }

    // ============ Tests ============

    function testFullCycleWithYieldDeployment() public {
        uint256 nav = vault.totalAssets();

        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);
        assertEq(srcNode.localAssets(address(vault)), 200 * ONE);
        assertEq(srcNode.remoteAssets(address(vault)), 300 * ONE);

        // Deliver to custodian
        bridge.deliverToCustodian(transferId);
        assertEq(dstCustodian.totalHeld(), 300 * ONE);

        // Deploy to yield
        vm.prank(custodianExecutor);
        dstCustodian.deployToProvider(ICustodianProvider(address(dstProvider)), 300 * ONE);
        assertEq(dstCustodian.totalDeployed(), 300 * ONE);

        // Simulate yield
        asset.mint(address(dstProvider), 15 * ONE);
        dstProvider.setYieldBps(500);

        // Withdraw (principal + yield)
        vm.prank(custodianExecutor);
        uint256 actual = dstCustodian.withdrawFromProvider(ICustodianProvider(address(dstProvider)), 300 * ONE);
        assertEq(dstCustodian.totalDeployed(), 0);

        // Bridge back principal only
        vm.prank(custodianExecutor);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId, 300 * ONE,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            300 * ONE
        );
        assertEq(dstCustodian.totalHeld(), actual - 300 * ONE);

        // Deliver return
        bridge.deliverReturn(transferId);

        assertEq(srcNode.localAssets(address(vault)), 500 * ONE);
        assertEq(srcNode.remoteAssets(address(vault)), 0);

        _rebalance(vault, 500 * ONE, meshProvider, providerA);
        _executeWithdraw(vault, THOUSAND, alice);
        // After alice exits, only bootstrap minAssets remains
        assertEq(vault.totalAssets(), ONE);
    }

    function testFullCycleWithBridgeFee() public {
        uint256 nav = vault.totalAssets();
        bridge.setFee(50);

        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 298 * ONE);

        uint256 expectedCredited = 300 * ONE - (300 * ONE * 50 / 10_000);
        assertEq(srcNode.remoteAssets(address(vault)), expectedCredited);

        _fullReturn(transferId, expectedCredited);

        assertEq(srcNode.localAssets(address(vault)), 200 * ONE + expectedCredited);
        assertEq(srcNode.remoteAssets(address(vault)), 0);
        assertEq(vault.totalAssets(), nav - (300 * ONE * 50 / 10_000));
    }

    function testFullCyclePartialLoss() public {
        uint256 nav = vault.totalAssets();

        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);

        uint256 lostAmount = 50 * ONE;
        uint256 returnAmount = 300 * ONE - lostAmount;

        _fullReturn(transferId, returnAmount);

        assertEq(srcNode.localAssets(address(vault)), 500 * ONE - lostAmount);
        assertEq(srcNode.remoteAssets(address(vault)), 0);
        assertEq(vault.totalAssets(), nav - lostAmount);
    }

    function testFullCycleWriteDownAndRecovery() public {
        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);

        // Write down before delivery (simulates stalled bridge)
        // Need to deliver first so bridgeBack can happen, then write down
        bridge.deliverToCustodian(transferId);

        srcNode.writeDown(transferId, 200 * ONE, keccak256("bridge stalled 48h"));
        assertEq(srcNode.balanceOf(address(vault)), 300 * ONE);
        assertEq(srcNode.pendingPrincipal(address(vault)), 300 * ONE);

        // Custodian returns full amount
        vm.prank(custodianExecutor);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId, 300 * ONE,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            300 * ONE
        );
        bridge.deliverReturn(transferId);

        assertEq(srcNode.localAssets(address(vault)), 500 * ONE);
        assertEq(srcNode.remoteAssets(address(vault)), 0);
        assertEq(srcNode.pendingPrincipal(address(vault)), 0);
        // vault = providerA(501) + mesh(500) + bootstrap accounting = 1001
        assertEq(vault.totalAssets(), 1_001 * ONE);
    }

    function testCustodianPauseBlocksOperationsDuringReturn() public {
        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);
        bridge.deliverToCustodian(transferId);

        vm.prank(custodianGuardian);
        dstCustodian.setPaused(true);

        vm.prank(custodianExecutor);
        vm.expectRevert(MeshCustodian.Paused.selector);
        dstCustodian.deployToProvider(ICustodianProvider(address(dstProvider)), 100 * ONE);

        vm.prank(custodianExecutor);
        vm.expectRevert(MeshCustodian.Paused.selector);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId, 100 * ONE,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            100 * ONE
        );

        dstCustodian.setPaused(false);

        // Complete the return
        vm.prank(custodianExecutor);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId, 300 * ONE,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            300 * ONE
        );
        bridge.deliverReturn(transferId);

        assertEq(srcNode.localAssets(address(vault)), 500 * ONE);
    }

    function testMultipleVaultsFullCycle() public {
        Rebalancer other = _deployVault();
        _initializeVault(other, _defaultProviders());

        IProvider[] memory providers = new IProvider[](4);
        providers[0] = providerA;
        providers[1] = providerB;
        providers[2] = providerC;
        providers[3] = meshProvider;
        other.setProviders(providers);
        other.grantRole(other.EXECUTOR_ROLE(), keeper);

        srcNode.configureVault(address(other), true, 2_000, 8_000);
        _executeDeposit(other, 500 * ONE, bob);

        _rebalance(vault, 400 * ONE, providerA, meshProvider);
        _rebalance(other, 300 * ONE, providerA, meshProvider);

        assertEq(srcNode.localAssets(address(vault)), 400 * ONE);
        assertEq(srcNode.localAssets(address(other)), 300 * ONE);

        vm.prank(keeper);
        bytes32 idA = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);

        _fullReturn(idA, 300 * ONE);

        assertEq(srcNode.localAssets(address(vault)), 400 * ONE);
        assertEq(srcNode.localAssets(address(other)), 300 * ONE);
    }

    function testCustodianYieldDoesNotAffectSourceNAV() public {
        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);
        bridge.deliverToCustodian(transferId);

        vm.prank(custodianExecutor);
        dstCustodian.deployToProvider(ICustodianProvider(address(dstProvider)), 300 * ONE);
        asset.mint(address(dstProvider), 50 * ONE);

        uint256 navBefore = vault.totalAssets();

        vm.prank(custodianExecutor);
        uint256 actual = dstCustodian.withdrawFromProvider(ICustodianProvider(address(dstProvider)), 300 * ONE);

        assertEq(vault.totalAssets(), navBefore);
        assertEq(srcNode.remoteAssets(address(vault)), 300 * ONE);

        // Return only principal
        vm.prank(custodianExecutor);
        dstCustodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId, 300 * ONE,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(srcNode)))),
            300 * ONE
        );
        bridge.deliverReturn(transferId);

        assertEq(vault.totalAssets(), navBefore);
        assertEq(srcNode.localAssets(address(vault)), 500 * ONE);
        assertEq(dstCustodian.totalHeld(), actual - 300 * ONE);
    }

    function testUserWithdrawDuringPendingTransfer() public {
        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);

        uint256 shares = vault.balanceOf(alice);
        vm.expectRevert(IRebalancer.InsufficientLiquidity.selector);
        vm.prank(alice);
        vault.withdraw(800 * ONE, alice, alice);
        assertEq(vault.balanceOf(alice), shares);

        _executeWithdraw(vault, 700 * ONE, alice);
        assertEq(srcNode.localAssets(address(vault)), 1 * ONE);
    }

    function testEndToEndWithDepositWithdrawDuringBridge() public {
        _rebalance(vault, 500 * ONE, providerA, meshProvider);
        vm.prank(keeper);
        bytes32 transferId = srcNode.bridgeOut(address(vault), ROUTE, 300 * ONE, 300 * ONE);

        // Bob's deposit goes to entryProvider (providerA), not mesh
        _executeDeposit(vault, 200 * ONE, bob);
        assertEq(srcNode.localAssets(address(vault)), 200 * ONE); // unchanged

        // Alice withdraws 300 from providerA (mesh is last)
        _executeWithdraw(vault, 300 * ONE, alice);
        assertEq(srcNode.localAssets(address(vault)), 200 * ONE); // unchanged

        // Return brings 300 back to mesh local
        _fullReturn(transferId, 300 * ONE);

        assertEq(srcNode.remoteAssets(address(vault)), 0);
        assertEq(srcNode.localAssets(address(vault)), 500 * ONE);
    }
}
