// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {FeeCapAsset, FeeCapSource, FeeCapProvider} from "./PerformanceFeeCap.t.sol";

/**
 * @title EntryProviderExecutorTest
 * @notice Covers `setEntryProvider` being callable by EXECUTOR_ROLE as well as ADMIN_ROLE,
 *         restricted on both paths to providers in the vault's current providers list.
 *
 * @dev Fork-free: reuses the delegatecall-safe doubles from `PerformanceFeeCap.t.sol`.
 *      Two providers, each backed by its own source, so per-provider balances show
 *      exactly where a deposit or withdrawal landed. The test contract is both admin
 *      and timelock, as in `PerformanceFeeCap.t.sol`.
 */
contract EntryProviderExecutorTest is Test {
    uint256 internal constant MIN_ASSETS = 1e6; // 1 USDC seed / dead shares
    uint256 internal constant ONE = 1e6;

    address internal treasury = makeAddr("treasury");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    FeeCapAsset internal asset;
    FeeCapSource internal sourceA;
    FeeCapSource internal sourceB;
    FeeCapProvider internal providerA;
    FeeCapProvider internal providerB;
    Rebalancer internal vault;

    function setUp() public {
        asset = new FeeCapAsset();
        sourceA = new FeeCapSource(IERC20(address(asset)));
        sourceB = new FeeCapSource(IERC20(address(asset)));
        providerA = new FeeCapProvider(sourceA);
        providerB = new FeeCapProvider(sourceB);

        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(this),
            ""
        );
        vault = Rebalancer(payable(address(proxy)));

        asset.mint(address(this), MIN_ASSETS);
        asset.approve(address(vault), MIN_ASSETS);

        IProvider[] memory providers = new IProvider[](2);
        providers[0] = providerA;
        providers[1] = providerB;

        vault.initialize(
            address(this), // admin
            address(this), // timelock
            address(asset),
            "Mock Rebalancer",
            "mrTOK",
            providers,
            treasury,
            0,
            0,
            MIN_ASSETS
        );

        vault.grantRole(vault.EXECUTOR_ROLE(), executor);
    }

    function _deposit(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _stray() internal returns (FeeCapProvider) {
        return new FeeCapProvider(new FeeCapSource(IERC20(address(asset))));
    }

    /*//////////////////////////////////////////////////////////////
                           EXECUTOR PATH
    //////////////////////////////////////////////////////////////*/

    function testExecutorSetsRegisteredEntryAndNextDepositLandsThere() public {
        assertEq(address(vault.getEntryProvider()), address(providerA), "fixture: entry is providers[0]");

        vm.expectEmit(true, true, true, true, address(vault));
        emit IRebalancer.EntryProviderUpdated(providerB);
        vm.prank(executor);
        vault.setEntryProvider(providerB);

        assertEq(address(vault.getEntryProvider()), address(providerB), "entry switched");

        _deposit(alice, 1_000 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 1_000 * ONE, "deposit lands at the new entry");
        assertEq(sourceA.balanceOf(address(vault)), MIN_ASSETS, "old entry keeps only the seed");
        assertEq(vault.totalAssets(), MIN_ASSETS + 1_000 * ONE, "deposit is counted");
    }

    function testExecutorCannotSetUnregisteredProvider() public {
        FeeCapProvider stray = _stray();

        vm.prank(executor);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(stray);

        vm.prank(executor);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(IProvider(address(0)));

        assertEq(address(vault.getEntryProvider()), address(providerA), "entry unchanged");
    }

    /// @dev Any address outside the current list, including address(0), is rejected.
    function testFuzzExecutorCannotSetUnlistedAddress(address candidate) public {
        vm.assume(candidate != address(providerA) && candidate != address(providerB));

        vm.prank(executor);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(IProvider(candidate));
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS
    //////////////////////////////////////////////////////////////*/

    function testAccountWithoutRoleCannotSetEntryProvider() public {
        vm.prank(mallory);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setEntryProvider(providerB);

        // the role check runs before provider validation
        FeeCapProvider stray = _stray();
        vm.prank(mallory);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setEntryProvider(stray);

        assertEq(address(vault.getEntryProvider()), address(providerA), "entry unchanged");
    }

    function testRevokedExecutorCannotSetEntryProvider() public {
        vault.revokeRole(vault.EXECUTOR_ROLE(), executor);

        vm.prank(executor);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setEntryProvider(providerB);
    }

    function testAdminStillSetsEntryProvider() public {
        assertFalse(vault.hasRole(vault.EXECUTOR_ROLE(), address(this)), "admin path must not lean on EXECUTOR_ROLE");

        vm.expectEmit(true, true, true, true, address(vault));
        emit IRebalancer.EntryProviderUpdated(providerB);
        vault.setEntryProvider(providerB);
        assertEq(address(vault.getEntryProvider()), address(providerB), "admin switched entry");

        // the admin path keeps its registered-only check
        FeeCapProvider stray = _stray();
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(stray);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERPLAY WITH WITHDRAW / setProviders
    //////////////////////////////////////////////////////////////*/

    /// @dev `_withdraw` walks `getProviders()` from index 0 and ignores the entry provider.
    function testWithdrawDrainsProvidersInListOrderNotEntryFirst() public {
        vm.prank(executor);
        vault.setEntryProvider(providerB);
        _deposit(alice, 1_000 * ONE); // lands at B; A holds only the seed

        vm.prank(alice);
        vault.withdraw(500 * ONE, alice, alice);

        assertEq(sourceA.balanceOf(address(vault)), 0, "providers[0] is drained first");
        assertEq(sourceB.balanceOf(address(vault)), 501 * ONE, "remainder comes from the entry");
        assertEq(asset.balanceOf(alice), 500 * ONE, "alice paid in full");
    }

    /// @dev Removing the current entry is rejected, even when it is empty.
    function testSetProvidersRejectsDroppingCurrentEntry() public {
        _deposit(alice, 1_000 * ONE); // lands at A
        vm.prank(executor);
        vault.setEntryProvider(providerB);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectRevert(IRebalancer.EntryProviderNotInProviders.selector);
        vault.setProviders(onlyA);
        assertEq(address(vault.getEntryProvider()), address(providerB), "entry unchanged");
        assertEq(vault.getProviders().length, 2, "provider list unchanged");

        uint256 assetsBefore = vault.totalAssets();
        _deposit(bob, 100 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 100 * ONE, "entry remains listed and receives deposits");
        assertEq(vault.totalAssets(), assetsBefore + 100 * ONE, "deposit is counted");
    }

    function testSetProvidersRemovesEmptyProviderAfterSwitchingEntry() public {
        vm.prank(executor);
        vault.setEntryProvider(providerB);
        vault.setEntryProvider(providerA);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectEmit(true, true, true, true, address(vault));
        emit IRebalancer.ProvidersUpdated(onlyA);
        vault.setProviders(onlyA);

        assertEq(vault.getProviders().length, 1);
        assertEq(address(vault.getEntryProvider()), address(providerA));
        assertEq(asset.allowance(address(vault), address(sourceB)), 0);
        _deposit(bob, 100 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), MIN_ASSETS + 100 * ONE);

        vm.prank(executor);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(providerB);
    }

    function testSetProvidersCannotHideAssetsAndDiluteExistingDepositor() public {
        vm.prank(executor);
        vault.setEntryProvider(providerB);
        _deposit(alice, 1_000 * ONE);
        vault.setEntryProvider(providerA);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectRevert(abi.encodeWithSelector(
            IRebalancer.ProviderHasAssets.selector, address(providerB), 1_000 * ONE
        ));
        vault.setProviders(onlyA);

        assertEq(vault.totalAssets(), MIN_ASSETS + 1_000 * ONE, "all assets remain in NAV");
        assertEq(vault.getProviders().length, 2, "funded provider stays listed");
        assertEq(asset.allowance(address(vault), address(sourceB)), type(uint256).max);

        // Before the fix this deposit bought 1,001 shares and later redeemed for 501 USDC.
        _deposit(bob, ONE);
        assertEq(vault.balanceOf(bob), ONE, "no shares minted against an incomplete NAV");
        IProvider[] memory both = new IProvider[](2);
        both[0] = providerA;
        both[1] = providerB;
        vault.setProviders(both);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        assertEq(asset.balanceOf(bob), ONE, "no profit from provider list changes");
        assertEq(vault.convertToAssets(vault.balanceOf(alice)), 1_000 * ONE);
    }

    function testFuzzSetProvidersRejectsRemovalWithAssets(uint96 amount) public {
        uint256 assets = bound(uint256(amount), MIN_ASSETS, 1e24);
        vm.prank(executor);
        vault.setEntryProvider(providerB);
        _deposit(alice, assets);
        vault.setEntryProvider(providerA);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectRevert(abi.encodeWithSelector(
            IRebalancer.ProviderHasAssets.selector, address(providerB), assets
        ));
        vault.setProviders(onlyA);
        assertEq(vault.totalAssets(), MIN_ASSETS + assets);
        assertEq(vault.balanceOf(alice), assets);
    }

    function testSetProvidersRejectsRemovalWithOneUnitOfDust() public {
        asset.mint(address(this), 1);
        asset.approve(address(sourceB), 1);
        sourceB.simulateYield(address(vault), 1);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectRevert(abi.encodeWithSelector(
            IRebalancer.ProviderHasAssets.selector, address(providerB), 1
        ));
        vault.setProviders(onlyA);
        assertEq(vault.totalAssets(), MIN_ASSETS + 1);
    }

    function testSetProvidersAllowsRemovalAfterRebalancingAllAssets() public {
        vm.prank(executor);
        vault.setEntryProvider(providerB);
        _deposit(alice, 1_000 * ONE);
        vault.setEntryProvider(providerA);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        IProvider[] memory from = new IProvider[](1);
        from[0] = providerB;
        IProvider[] memory to = new IProvider[](1);
        to[0] = providerA;
        vm.prank(executor);
        vault.rebalance(amounts, from, to);

        assertEq(sourceB.balanceOf(address(vault)), 0);
        vault.setProviders(to);
        assertEq(vault.totalAssets(), MIN_ASSETS + 1_000 * ONE);
        assertEq(asset.allowance(address(vault), address(sourceB)), 0);
        vm.prank(alice);
        vault.withdraw(1_000 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000 * ONE);
        assertEq(vault.totalAssets(), MIN_ASSETS);
    }

    function testExecutorCannotChangeProviderList() public {
        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.prank(executor);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setProviders(onlyA);
    }

    function testSetProvidersKeepsListedEntry() public {
        vm.prank(executor);
        vault.setEntryProvider(providerB);

        IProvider[] memory same = new IProvider[](2);
        same[0] = providerA;
        same[1] = providerB;
        vault.setProviders(same);

        assertEq(address(vault.getEntryProvider()), address(providerB), "listed entry is kept");
    }

    function testSetProvidersRejectsEmptyList() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setProviders(new IProvider[](0));
    }
}
