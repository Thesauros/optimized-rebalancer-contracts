// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MeshNode} from "../../contracts/crosschain/MeshNode.sol";
import {MeshProvider} from "../../contracts/crosschain/MeshProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockMeshBridgeAdapter} from "./MockMeshBridgeAdapter.sol";

/// @dev Deliberately adversarial token; not a supported production asset.
contract MeshCallbackToken is MockERC20 {
    address public callbackTarget;
    bytes public callback;
    bytes public callbackResult;
    bool public callbackSucceeded;
    bool public noTransferFrom;
    bool public taxedTransfer;

    constructor() MockERC20("Callback USD", "cUSD", 6) {}

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callback = data;
    }

    function setNoTransferFrom(bool value) external {
        noTransferFrom = value;
    }

    function setTaxedTransfer(bool value) external {
        taxedTransfer = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (taxedTransfer && value != 0) {
            _transfer(msg.sender, to, value - 1);
            _burn(msg.sender, 1);
            return true;
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (noTransferFrom) return true;
        bool result = super.transferFrom(from, to, value);
        if (msg.sender == callbackTarget) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callback);
        }
        return result;
    }
}

/// @dev Test-only registered vault context; production registers trusted Rebalancers.
contract MeshProviderHarness {
    address public immutable asset;

    constructor(address token) {
        asset = token;
    }

    function deposit(MeshProvider provider, uint256 amount, address vaultArgument) external {
        (bool ok, bytes memory result) =
            address(provider).delegatecall(abi.encodeCall(provider.deposit, (amount, IRebalancer(vaultArgument))));
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
    }
}

contract MeshTokenBoundaryTest is Test {
    MeshCallbackToken internal token;
    MeshNode internal node;
    MeshProvider internal provider;
    MeshProviderHarness internal vault;
    MockMeshBridgeAdapter internal bridge;
    address internal keeper = makeAddr("keeper");
    address internal remote = makeAddr("remote");
    bytes32 internal constant ROUTE = keccak256("route");

    function setUp() public {
        token = new MeshCallbackToken();
        node = new MeshNode(address(token), address(this), keeper, address(this));
        provider = new MeshProvider(node);
        vault = new MeshProviderHarness(address(token));
        bridge = new MockMeshBridgeAdapter();
        node.configureVault(address(vault), true, 0, 10_000);
        node.addRoute(ROUTE, address(bridge), 42161, _peer(), 1_000e6, 0);
        token.mint(address(vault), 100e6);
    }

    function _peer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(remote)));
    }

    function testMismatchedVaultArgumentCannotRedirectDeposit() public {
        vm.expectRevert(MeshProvider.InvalidContext.selector);
        vault.deposit(provider, 100e6, remote);
        assertEq(token.balanceOf(address(vault)), 100e6);
        assertEq(node.totalAssets(), 0);
    }

    function testWrongAssetContextFailsBeforeTransferring() public {
        MeshProviderHarness wrong = new MeshProviderHarness(address(bridge));
        vm.expectRevert(MeshProvider.InvalidContext.selector);
        wrong.deposit(provider, 1, address(wrong));
        vm.expectRevert(MeshNode.InvalidConfiguration.selector);
        node.configureVault(address(wrong), true, 0, 10_000);
    }

    function testCreditWithoutPhysicalTransferFails() public {
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        vm.prank(address(vault));
        node.depositFromVault(100e6);
        assertEq(node.totalAssets(), 0);
    }

    function testDonationsCannotMaskTaxedProviderDeposit() public {
        token.mint(address(node), 1e6);
        token.setTaxedTransfer(true);
        vm.expectRevert(MeshProvider.UnexpectedTokenAmount.selector);
        vault.deposit(provider, 100e6, address(vault));
        assertEq(token.balanceOf(address(vault)), 100e6);
        assertEq(token.balanceOf(address(node)), 1e6);
        assertEq(node.totalAssets(), 0);
    }

    function testReturnWithoutTokenMovementRevertsAndCanBeRetried() public {
        bytes32 id = _outbound();
        token.setNoTransferFrom(true);
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        bridge.deliverReturn(id, 100e6);
        assertEq(node.remoteAssets(address(vault)), 100e6);
        assertEq(node.localAssets(address(vault)), 0);
        assertEq(token.balanceOf(remote), 100e6);
        token.setNoTransferFrom(false);
        bridge.deliverReturn(id, 100e6);
        assertEq(node.localAssets(address(vault)), 100e6);
    }

    function testTaxedWithdrawalCannotBurnClaimWithoutPayingFullAmount() public {
        vault.deposit(provider, 100e6, address(vault));
        token.setTaxedTransfer(true);
        vm.expectRevert(MeshNode.UnexpectedTokenAmount.selector);
        vm.prank(address(vault));
        node.withdrawToVault(50e6);
        assertEq(node.localAssets(address(vault)), 100e6);
        assertEq(token.balanceOf(address(node)), 100e6);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testTokenCallbackCannotReenterFinalSettlement() public {
        bytes32 id = _outbound();
        token.setCallback(address(node), abi.encodeCall(node.receiveReturn, (id, 42161, _peer(), 0)));
        bridge.deliverReturn(id, 100e6);
        assertFalse(token.callbackSucceeded());
        assertEq(bytes4(token.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(node.localAssets(address(vault)), 100e6);
        assertEq(node.remoteAssets(address(vault)), 0);
        assertEq(node.totalAssets(), 100e6);
    }

    function _outbound() internal returns (bytes32 id) {
        vault.deposit(provider, 100e6, address(vault));
        vm.prank(keeper);
        id = node.bridgeOut(address(vault), ROUTE, 100e6, 100e6);
        bridge.deliverOutbound(id);
        vm.prank(remote);
        token.approve(address(bridge), type(uint256).max);
    }
}
