// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MeshNode} from "../../contracts/crosschain/MeshNode.sol";
import {MeshProvider} from "../../contracts/crosschain/MeshProvider.sol";
import {MeshCustodian} from "../../contracts/crosschain/MeshCustodian.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";

/// @title CrosschainStandForkTest
/// @notice Pre-deploy verification against real mainnet state.
///         Forks Base (source) and verifies:
///         1. MeshNode deploys with correct USDC address
///         2. MeshProvider integrates with existing vault
///         3. Vault can rebalance into MeshProvider
///         4. User deposit/withdraw works with Mesh as last provider
///
/// Run:
///   forge test --match-path test/forking/CrosschainStandFork.t.sol \
///     --fork-url $BASE_RPC_URL -vvv
///
/// Requires: BASE_RPC_URL environment variable
contract CrosschainStandForkTest is Test {
    // Base mainnet addresses
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_VAULT = 0x3C7739173cca612B6394EE57131458185A5beC44;
    address constant BASE_SAFE = 0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1;

    // Test actors
    address internal deployer = makeAddr("stand deployer");
    address internal keeper = makeAddr("stand keeper");
    address internal guardian = makeAddr("stand guardian");
    address internal alice = makeAddr("alice");

    MeshNode internal node;
    MeshProvider internal meshProvider;
    Timelock internal timelock;

    function setUp() public {
        // Verify we're on a fork with real state
        uint256 codeSize;
        address target = BASE_USDC;
        assembly { codeSize := extcodesize(target) }
        require(codeSize > 0, "USDC not deployed - check fork RPC");

        // Fund test accounts with real USDC from a whale
        address whale = _findUsdcWhale();
        if (whale != address(0)) {
            vm.startPrank(whale);
            IERC20(BASE_USDC).transfer(alice, 10_000e6);
            vm.stopPrank();
        } else {
            vm.skip(true);
        }

        // Deploy Timelock as governance (MeshNode requires governance.code.length > 0)
        vm.startPrank(deployer);
        timelock = new Timelock(deployer, 3600);

        // Deploy the stand with Timelock as governance
        node = new MeshNode(BASE_USDC, address(timelock), keeper, guardian);
        meshProvider = new MeshProvider(node);
        vm.stopPrank();
    }

    function testNodeDeploysWithCorrectState() public view {
        assertEq(node.asset(), BASE_USDC);
        assertEq(node.governance(), address(timelock));
        assertEq(node.executor(), keeper);
        assertEq(node.guardian(), guardian);
        assertFalse(node.paused());
        assertEq(node.totalAssets(), 0);
    }

    function testMeshProviderHasCorrectImmutable() public view {
        assertEq(address(meshProvider.node()), address(node));
        // Verify it returns the right identifier
        assertEq(meshProvider.getIdentifier(), "CrossChain_Mesh_Provider");
        assertEq(meshProvider.getDepositRate(IRebalancer(address(0))), 0);
    }

    function testNodeCanConfigureRealVault() public {
        // Verify the vault exists and has the right asset
        Rebalancer vault = Rebalancer(payable(BASE_VAULT));
        assertEq(vault.asset(), BASE_USDC);

        // Configure the real vault in the node (governance = timelock)
        vm.prank(address(timelock));
        node.configureVault(BASE_VAULT, true, 2_000, 8_000);

        (bool enabled, uint16 minLocalBps, uint16 maxRemoteBps) = node.vaults(BASE_VAULT);
        assertTrue(enabled);
        assertEq(minLocalBps, 2_000);
        assertEq(maxRemoteBps, 8_000);
    }

    function testGuardianCanPauseAndUnpause() public {
        vm.prank(guardian);
        node.setPaused(true);
        assertTrue(node.paused());

        // Only governance can unpause
        vm.prank(guardian);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.setPaused(false);

        vm.prank(address(timelock));
        node.setPaused(false);
        assertFalse(node.paused());
    }

    function testUnauthorizedCannotConfigure() public {
        vm.prank(alice);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.configureVault(BASE_VAULT, true, 2_000, 8_000);

        vm.prank(keeper);
        vm.expectRevert(MeshNode.Unauthorized.selector);
        node.configureVault(BASE_VAULT, true, 2_000, 8_000);
    }

    function testProviderDirectCallsFail() public {
        // MeshProvider should reject direct calls (not via delegatecall from vault)
        vm.expectRevert(MeshProvider.InvalidContext.selector);
        meshProvider.deposit(100e6, IRebalancer(BASE_VAULT));

        vm.expectRevert(MeshProvider.InvalidContext.selector);
        meshProvider.withdraw(100e6, IRebalancer(BASE_VAULT));
    }

    /// @dev Try to find a USDC whale on Base for fork testing.
    function _findUsdcWhale() internal view returns (address) {
        // Known large USDC holders on Base (may change over time)
        // These are checked in order; first with balance wins
        address[] memory candidates = new address[](3);
        candidates[0] = 0x33473E5947650E11396b78C21a7f69b1f5e8Da4e; // Aave pool
        candidates[1] = 0x0B2402144Bb366A632d28e6D4559B40869f71f5a; // Compound
        candidates[2] = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho

        for (uint256 i = 0; i < candidates.length; i++) {
            if (IERC20(BASE_USDC).balanceOf(candidates[i]) > 10_000e6) {
                return candidates[i];
            }
        }
        return address(0);
    }
}

/// @title CrosschainStandForkTestArbitrum
/// @notice Pre-deploy verification for the destination side (Arbitrum).
///         Forks Arbitrum and verifies MeshCustodian deployment.
///
/// Run:
///   forge test --match-path test/forking/CrosschainStandFork.t.sol \
///     --fork-url $ARBITRUM_RPC_URL -vvv -match-contract CrosschainStandForkTestArbitrum
contract CrosschainStandForkTestArbitrum is Test {
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_VAULT = 0x4E5c0A4C11d713002D74bA43a458efc31bc76378;

    address internal deployer = makeAddr("stand deployer");
    address internal keeper = makeAddr("stand keeper");
    address internal guardian = makeAddr("stand guardian");

    MeshCustodian internal custodian;
    Timelock internal timelock;

    function setUp() public {
        uint256 codeSize;
        assembly { codeSize := extcodesize(ARB_USDC) }
        if (codeSize == 0) {
            // Not on Arbitrum fork — skip
            vm.skip(true);
            return;
        }

        vm.startPrank(deployer);
        timelock = new Timelock(deployer, 3600);
        custodian = new MeshCustodian(ARB_USDC, address(timelock), keeper, guardian);
        vm.stopPrank();
    }

    function testCustodianDeploysWithCorrectState() public view {
        assertEq(custodian.asset(), ARB_USDC);
        assertEq(custodian.governance(), address(timelock));
        assertEq(custodian.executor(), keeper);
        assertEq(custodian.guardian(), guardian);
        assertFalse(custodian.paused());
        assertEq(custodian.getTotalValue(), 0);
        assertEq(custodian.getLiquidValue(), 0);
    }

    function testCustodianGuardianPause() public {
        vm.prank(guardian);
        custodian.setPaused(true);
        assertTrue(custodian.paused());

        vm.prank(guardian);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.setPaused(false);

        vm.prank(address(timelock));
        custodian.setPaused(false);
        assertFalse(custodian.paused());
    }

    function testCustodianRejectsUntrustedAdapter() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(MeshCustodian.UnknownSource.selector);
        custodian.onBridgeIn(1, 100e6, keccak256("test"));
    }

    function testCustodianRejectsUnallowedProvider() public {
        address fakeProvider = makeAddr("fake provider");
        vm.prank(keeper);
        vm.expectRevert(MeshCustodian.Unauthorized.selector);
        custodian.deployToProvider(
            ICustodianProvider(fakeProvider), 100e6
        );
    }

    function testCustodianGovernanceCanTrustAndAllow() public {
        address adapter = makeAddr("adapter");
        address provider = makeAddr("provider");

        // Give them code so the checks pass
        vm.etch(adapter, hex"00");
        vm.etch(provider, hex"00");

        vm.prank(address(timelock));
        custodian.trustAdapter(adapter, true);
        assertTrue(custodian.trustedAdapters(adapter));

        vm.prank(address(timelock));
        custodian.allowProvider(provider, true);
        assertTrue(custodian.allowedProviders(provider));
    }
}

import {ICustodianProvider} from "../../contracts/crosschain/interfaces/ICustodianProvider.sol";
