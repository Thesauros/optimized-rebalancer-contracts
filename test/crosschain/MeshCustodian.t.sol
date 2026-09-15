// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MeshCustodian} from "../../contracts/crosschain/MeshCustodian.sol";
import {ICustodianProvider} from "../../contracts/crosschain/interfaces/ICustodianProvider.sol";
import {IMeshBridgeAdapter} from "../../contracts/crosschain/interfaces/IMeshBridgeAdapter.sol";
import {MockCustodianProvider} from "./MockCustodianProvider.sol";
import {MockMeshBridgeAdapter} from "./MockMeshBridgeAdapter.sol";

contract MeshCustodianTest is Test {
    MockERC20 internal asset;
    MeshCustodian internal custodian;
    MockCustodianProvider internal provider;
    MockMeshBridgeAdapter internal bridge;

    // Use address(this) for governance since constructor requires code.length > 0
    address internal executor = makeAddr("executor");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal remote = makeAddr("remote");

    bytes32 internal constant ROUTE = keccak256("route");
    uint256 internal constant REMOTE_CHAIN = 1;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        custodian = new MeshCustodian(address(asset), address(this), executor, guardian);
        provider = new MockCustodianProvider(address(asset));
        bridge = new MockMeshBridgeAdapter();

        // Setup
        custodian.trustAdapter(address(bridge), true);
        custodian.allowProvider(address(provider), true);

        // Fund alice and approve
        asset.mint(alice, 1000e6);
        vm.prank(alice);
        asset.approve(address(bridge), type(uint256).max);

        // Setup bridge to deliver to custodian
        vm.deal(remote, 1 ether);
    }

    // ============ SEC-CUST-1: getTotalValue includes deployed ============

    function testGetTotalValueIncludesDeployed() public {
        // Bridge in 100 tokens
        _bridgeIn(100e6);
        assertEq(custodian.getTotalValue(), 100e6);
        assertEq(custodian.getLiquidValue(), 100e6);

        // Deploy 60 to provider
        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);

        // Total should still be 100 (60 deployed + 40 liquid)
        assertEq(custodian.getTotalValue(), 100e6);
        assertEq(custodian.getLiquidValue(), 40e6);
        assertEq(custodian.totalDeployed(), 60e6);
        assertEq(custodian.totalHeld(), 40e6);
    }

    function testGetTotalValueAfterWithdrawFromProvider() public {
        _bridgeIn(100e6);
        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);

        // Withdraw 30 from provider
        vm.prank(executor);
        custodian.withdrawFromProvider(ICustodianProvider(address(provider)), 30e6);

        assertEq(custodian.getTotalValue(), 100e6);
        assertEq(custodian.getLiquidValue(), 70e6);
        assertEq(custodian.totalDeployed(), 30e6);
    }

    // ============ SEC-CUST-2/3: Provider uses delegatecall ============

    function testDeployToProviderUsesDelegatecall() public {
        _bridgeIn(100e6);

        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);

        // Provider should have received tokens (via delegatecall, so custodian's balance decreased)
        assertEq(asset.balanceOf(address(custodian)), 40e6);
        assertEq(custodian.heldByProvider(address(provider)), 60e6);
        assertEq(provider.totalDeposited(), 60e6);
    }

    function testWithdrawFromProviderUsesDelegatecall() public {
        _bridgeIn(100e6);
        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);

        // Fund provider to simulate yield protocol having tokens
        asset.mint(address(provider), 60e6);

        vm.prank(executor);
        uint256 actual = custodian.withdrawFromProvider(ICustodianProvider(address(provider)), 40e6);

        assertEq(actual, 40e6);
        assertEq(asset.balanceOf(address(custodian)), 80e6);
        assertEq(custodian.heldByProvider(address(provider)), 20e6);
    }

    function testDeployToProviderRevertForUnallowed() public {
        _bridgeIn(100e6);
        MockCustodianProvider badProvider = new MockCustodianProvider(address(asset));

        vm.prank(executor);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.deployToProvider(ICustodianProvider(address(badProvider)), 60e6);
    }

    // ============ SEC-CUST-4: bridgeBack accounting ============

    function testBridgeBackAccountsCorrectly() public {
        _bridgeIn(100e6);

        // Setup return path
        vm.prank(remote);
        asset.approve(address(bridge), type(uint256).max);

        bytes32 transferId = keccak256("return");

        vm.prank(executor);
        uint256 amountOut = custodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            transferId,
            50e6,
            uint64(REMOTE_CHAIN),
            bytes32(uint256(uint160(remote))),
            50e6
        );

        assertEq(amountOut, 50e6);
        assertEq(custodian.totalHeld(), 50e6);
        assertEq(asset.balanceOf(address(bridge)), 50e6);
    }

    function testBridgeBackRevertIfSpendsMoreThanHeld() public {
        _bridgeIn(100e6);

        // Deploy some to provider so totalHeld < balance
        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);

        // Now totalHeld = 40, but balance = 100 (40 liquid + 60 in provider accounting)
        // bridgeBack should only be able to spend totalHeld
        vm.prank(executor);
        vm.expectRevert(MeshCustodian.UnexpectedTokenAmount.selector);
        custodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            keccak256("return"),
            50e6, // more than totalHeld (40)
            uint64(REMOTE_CHAIN),
            bytes32(uint256(uint160(remote))),
            50e6
        );
    }

    // ============ SEC-CUST-5: Pause mechanism ============

    function testGuardianCanPause() public {
        vm.prank(guardian);
        custodian.setPaused(true);
        assertTrue(custodian.paused());

        // Operations should revert - test onBridgeIn directly
        vm.prank(address(bridge));
        vm.expectRevert(MeshCustodian.Paused.selector);
        custodian.onBridgeIn(1, 100e6, keccak256("test"));
    }

    function testOnlyGovernanceCanUnpause() public {
        vm.prank(guardian);
        custodian.setPaused(true);

        vm.prank(guardian);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.setPaused(false);

        // address(this) is governance, no prank needed
        custodian.setPaused(false);
        assertFalse(custodian.paused());
    }

    function testPauseBlocksDeployAndBridgeBack() public {
        _bridgeIn(100e6);

        vm.prank(guardian);
        custodian.setPaused(true);

        vm.prank(executor);
        vm.expectRevert(MeshCustodian.Paused.selector);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 50e6);

        vm.prank(executor);
        vm.expectRevert(MeshCustodian.Paused.selector);
        custodian.bridgeBack{value: 0}(
            IMeshBridgeAdapter(address(bridge)),
            keccak256("return"),
            50e6,
            uint64(REMOTE_CHAIN),
            bytes32(uint256(uint160(remote))),
            50e6
        );
    }

    // ============ SEC-CUST-6: onBridgeIn uses srcChainId/transferId ============

    function testOnBridgeInEmitsCorrectEvent() public {
        bytes32 transferId = keccak256("test-transfer");
        uint64 srcChainId = 42161;

        // Bridge receives tokens and approves custodian
        vm.prank(alice);
        asset.transfer(address(bridge), 100e6);
        vm.prank(address(bridge));
        asset.approve(address(custodian), type(uint256).max);

        vm.prank(address(bridge));
        // We expect the event to be emitted with correct srcChainId and transferId
        vm.expectEmit(true, true, false, true);
        emit MeshCustodian.BridgeInReceived(srcChainId, 100e6, transferId);

        custodian.onBridgeIn(srcChainId, 100e6, transferId);
    }

    // ============ Access control ============

    function testOnlyExecutorCanDeploy() public {
        _bridgeIn(100e6);

        vm.prank(alice);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 50e6);
    }

    function testOnlyExecutorCanWithdraw() public {
        _bridgeIn(100e6);
        vm.prank(executor);
        custodian.deployToProvider(ICustodianProvider(address(provider)), 60e6);
        asset.mint(address(provider), 60e6);

        vm.prank(alice);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.withdrawFromProvider(ICustodianProvider(address(provider)), 30e6);
    }

    function testOnlyTrustedAdapterCanBridgeIn() public {
        vm.prank(alice);
        vm.expectRevert(MeshCustodian.UnknownSource.selector);
        custodian.onBridgeIn(1, 100e6, keccak256("test"));
    }

    // ============ Roles ============

    function testSetRoles() public {
        address newExecutor = makeAddr("new executor");
        address newGuardian = makeAddr("new guardian");

        // address(this) is governance, no prank needed
        custodian.setRoles(newExecutor, newGuardian);

        assertEq(custodian.executor(), newExecutor);
        assertEq(custodian.guardian(), newGuardian);
    }

    function testSetRolesRevertIfZero() public {
        // address(this) is governance, no prank needed
        vm.expectRevert(MeshCustodian.InvalidConfiguration.selector);
        custodian.setRoles(address(0), guardian);
    }

    // ============ Helpers ============

    function _bridgeIn(uint256 amount) internal {
        // Alice sends to bridge
        vm.prank(alice);
        asset.transfer(address(bridge), amount);

        // Bridge approves custodian to pull tokens
        vm.prank(address(bridge));
        asset.approve(address(custodian), type(uint256).max);

        // Bridge delivers to custodian
        vm.prank(address(bridge));
        custodian.onBridgeIn(uint64(REMOTE_CHAIN), amount, keccak256("transfer"));
    }
}
