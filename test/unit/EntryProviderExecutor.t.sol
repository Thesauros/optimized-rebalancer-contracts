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

    /// @dev The executor can point the entry at a provider the timelock is about to remove
    ///      (front-run or plain race). `setProviders` must then move the entry back into
    ///      the list, or deposits would land where `totalAssets` and `_withdraw` cannot see.
    function testSetProvidersDroppingEntryResetsItToHead() public {
        _deposit(alice, 1_000 * ONE); // lands at A
        vm.prank(executor);
        vault.setEntryProvider(providerB);

        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectEmit(true, true, true, true, address(vault));
        emit IRebalancer.EntryProviderUpdated(providerA);
        vault.setProviders(onlyA);
        assertEq(address(vault.getEntryProvider()), address(providerA), "entry reset to providers[0]");

        uint256 assetsBefore = vault.totalAssets();
        _deposit(bob, 100 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 0, "nothing lands at the de-listed provider");
        assertEq(vault.totalAssets(), assetsBefore + 100 * ONE, "deposit is counted");
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
