// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {FeeCapAsset, FeeCapSource, FeeCapProvider} from "./PerformanceFeeCap.t.sol";

/// @notice Releases one unit less than asked on withdraw (rounding-loss market).
contract ShortSource is FeeCapSource {
    constructor(IERC20 asset_) FeeCapSource(asset_) {}

    function debitAndSendShort(address vault, uint256 amount, address to) external {
        balances[vault] -= amount;
        asset.transfer(to, amount - 1);
    }
}

/// @dev Minimal provider over a FeeCapSource-like ledger; delegatecalled, no storage.
abstract contract LedgerProvider is IProvider {
    FeeCapSource internal immutable _ledger;

    constructor(FeeCapSource ledger_) {
        _ledger = ledger_;
    }

    function getIdentifier() external pure returns (string memory) {
        return "Ledger";
    }

    function getSource(address, address, address) external view returns (address) {
        return address(_ledger);
    }

    function getDepositBalance(address user, IRebalancer) external view returns (uint256) {
        return _ledger.balanceOf(user);
    }

    function getDepositRate(IRebalancer) external pure returns (uint256) {
        return 0;
    }
}

contract ShortProvider is LedgerProvider {
    constructor(ShortSource source_) LedgerProvider(source_) {}

    function deposit(uint256 amount, IRebalancer vault) external returns (bool) {
        _ledger.creditDeposit(address(vault), amount);
        return true;
    }

    function withdraw(uint256 amount, IRebalancer vault) external returns (bool) {
        ShortSource(address(_ledger)).debitAndSendShort(address(vault), amount, address(vault));
        return true;
    }
}

/// @notice A provider whose every call reverts after listing.
contract BrokenProvider is IProvider {
    address private immutable _source;
    bool private immutable _brokenSource;

    constructor(address source_, bool brokenSource_) {
        _source = source_;
        _brokenSource = brokenSource_;
    }

    function getIdentifier() external pure returns (string memory) {
        return "Broken";
    }

    function getSource(address, address, address) external view returns (address) {
        if (_brokenSource && msg.sender != address(0) && gasleft() > 0 && _isRemoval()) revert("broken source");
        return _source;
    }

    /// @dev During listing the vault still has no allowance to our source; during removal it does.
    function _isRemoval() internal view returns (bool) {
        return IERC20(IRebalancer(msg.sender).asset()).allowance(msg.sender, _source) != 0;
    }

    function deposit(uint256, IRebalancer) external pure returns (bool) {
        revert("broken");
    }

    function withdraw(uint256, IRebalancer) external pure returns (bool) {
        revert("broken");
    }

    function getDepositBalance(address, IRebalancer) external pure returns (uint256) {
        revert("broken");
    }

    function getDepositRate(IRebalancer) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Tries to re-enter the vault from inside the delegatecalled deposit.
contract ReentrantProvider is LedgerProvider {
    constructor(FeeCapSource source_) LedgerProvider(source_) {}

    function deposit(uint256 amount, IRebalancer vault) external returns (bool) {
        if (amount == 7) vault.deposit(7, address(this));
        _ledger.creditDeposit(address(vault), amount);
        return true;
    }

    function withdraw(uint256 amount, IRebalancer vault) external returns (bool) {
        _ledger.debitAndSend(address(vault), amount, address(vault));
        return true;
    }
}

contract RebalancerHardeningTest is Test {
    uint256 internal constant ONE = 1e6;

    address internal admin = makeAddr("admin");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

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
        IProvider[] memory ps = new IProvider[](2);
        ps[0] = providerA;
        ps[1] = providerB;
        vault = _newVault(ps);
        _deposit(alice, 1_000 * ONE);
    }

    function _newVault(IProvider[] memory ps) internal returns (Rebalancer v) {
        v = Rebalancer(payable(address(new TransparentUpgradeableProxy(address(new Rebalancer()), address(this), ""))));
        asset.mint(address(this), ONE);
        asset.approve(address(v), ONE);
        // admin is separate from the timelock (this contract) to test the split
        v.initialize(admin, address(this), address(asset), "v", "v", ps, treasury, 0, 0, ONE);
        bytes32 executorRole = v.EXECUTOR_ROLE();
        vm.prank(admin);
        v.grantRole(executorRole, executor);
    }

    function _deposit(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _rebalance(IProvider from, IProvider to, uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory f = new IProvider[](1);
        IProvider[] memory t = new IProvider[](1);
        amounts[0] = amount;
        f[0] = from;
        t[0] = to;
        vm.prank(executor);
        vault.rebalance(amounts, f, t);
    }

    /*//////////////////////////////////////////////////////////////
                             PROVIDER CAPS
    //////////////////////////////////////////////////////////////*/

    function testCapBlocksRebalanceAboveCap() public {
        vault.setProviderCap(providerB, 3_000); // 30%
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(providerB)));
        _rebalance(providerA, providerB, 400 * ONE);

        _rebalance(providerA, providerB, 300 * ONE);
        assertEq(providerB.getDepositBalance(address(vault), vault), 300 * ONE);
    }

    function testCapBlocksDepositIntoCappedEntryProvider() public {
        vault.setProviderCap(providerA, 5_000); // all 1,001 sits in A already
        asset.mint(alice, 10 * ONE);
        vm.startPrank(alice);
        asset.approve(address(vault), 10 * ONE);
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(providerA)));
        vault.deposit(10 * ONE, alice);
        vm.stopPrank();
    }

    function testUncappedByDefault() public view {
        assertEq(vault.getProviderCap(providerA), 0);
        assertEq(vault.getProviderCap(providerB), 0);
    }

    function testAdminMayOnlyLowerCapsTimelockMayRaise() public {
        vm.startPrank(admin);
        vault.setProviderCap(providerB, 5_000); // from uncapped: lowering risk
        vault.setProviderCap(providerB, 4_000);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setProviderCap(providerB, 6_000);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setProviderCap(providerB, 0); // uncapping
        vm.stopPrank();

        vault.setProviderCap(providerB, 0); // timelock
        assertEq(vault.getProviderCap(providerB), 0);

        vm.prank(executor);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setProviderCap(providerB, 1_000);
    }

    function testCapOnlyForListedProviders() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setProviderCap(IProvider(makeAddr("stranger")), 1_000);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setProviderCap(providerB, 10_001);
    }

    /*//////////////////////////////////////////////////////////////
                         MEASURED REBALANCE
    //////////////////////////////////////////////////////////////*/

    function testRebalanceMovesWhatArrivedNotIdleBalance() public {
        ShortSource shortSource = new ShortSource(IERC20(address(asset)));
        ShortProvider shortProvider = new ShortProvider(shortSource);
        IProvider[] memory ps = new IProvider[](2);
        ps[0] = shortProvider;
        ps[1] = providerB;
        vault = _newVault(ps);
        _deposit(alice, 1_000 * ONE);

        asset.mint(address(vault), 5 * ONE); // idle donation must stay untouched
        _rebalance(shortProvider, providerB, 100 * ONE);

        assertEq(providerB.getDepositBalance(address(vault), vault), 100 * ONE - 1, "moved exactly what was released");
        assertEq(asset.balanceOf(address(vault)), 5 * ONE, "idle vault balance not consumed");
    }

    /*//////////////////////////////////////////////////////////////
                    BROKEN PROVIDERS DO NOT FREEZE THE VAULT
    //////////////////////////////////////////////////////////////*/

    function testBrokenProviderDoesNotFreezeNavOrExits() public {
        BrokenProvider broken = new BrokenProvider(address(sourceB), false);
        IProvider[] memory ps = new IProvider[](3);
        ps[0] = providerA;
        ps[1] = providerB;
        ps[2] = broken;
        vault.setProviders(ps);

        assertEq(vault.totalAssets(), 1_001 * ONE, "broken provider reads as zero, NAV still computes");
        assertFalse(vault.providersHealthy());

        // entries would be priced against an incomplete NAV: refused
        asset.mint(bob, 10 * ONE);
        vm.startPrank(bob);
        asset.approve(address(vault), 10 * ONE);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.deposit(10 * ONE, bob);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.mint(10 * ONE, bob);
        vm.stopPrank();

        // exits still work (under-stated NAV is the safe side for them)
        vm.prank(alice);
        vault.withdraw(100 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 100 * ONE);

        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory f = new IProvider[](1);
        IProvider[] memory t = new IProvider[](1);
        amounts[0] = 1;
        f[0] = broken;
        t[0] = providerA;
        vm.prank(executor);
        vm.expectRevert(IRebalancer.InvalidProvider.selector);
        vault.rebalance(amounts, f, t);
    }

    /*//////////////////////////////////////////////////////////////
                    PROVIDER LIST: APPROVALS AND ENTRY
    //////////////////////////////////////////////////////////////*/

    function testRemovedProviderApprovalIsRevoked() public {
        assertEq(asset.allowance(address(vault), address(sourceB)), type(uint256).max);
        IProvider[] memory ps = new IProvider[](1);
        ps[0] = providerA;
        vault.setProviders(ps);
        assertEq(asset.allowance(address(vault), address(sourceB)), 0, "stale approval revoked");
        assertEq(asset.allowance(address(vault), address(sourceA)), type(uint256).max);
    }

    function testCannotDropTheEntryProvider() public {
        IProvider[] memory ps = new IProvider[](1);
        ps[0] = providerB;
        vm.expectRevert(IRebalancer.EntryProviderNotInProviders.selector);
        vault.setProviders(ps);
    }

    function testBrokenProviderCanStillBeRemoved() public {
        FeeCapSource sourceC = new FeeCapSource(IERC20(address(asset)));
        BrokenProvider broken = new BrokenProvider(address(sourceC), true);
        IProvider[] memory ps = new IProvider[](3);
        ps[0] = providerA;
        ps[1] = providerB;
        ps[2] = broken;
        vault.setProviders(ps);

        IProvider[] memory back = new IProvider[](2);
        back[0] = providerA;
        back[1] = providerB;
        vm.expectEmit(true, false, false, false);
        emit IRebalancer.StaleApprovalRevokeFailed(address(broken));
        vault.setProviders(back);
        assertEq(vault.getProviders().length, 2);
    }

    function testRevokeStaleApprovalIsSelfOnly() public {
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.revokeStaleApproval(providerA);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function testProviderCannotReenterDeposit() public {
        FeeCapSource sourceR = new FeeCapSource(IERC20(address(asset)));
        ReentrantProvider re = new ReentrantProvider(sourceR);
        IProvider[] memory ps = new IProvider[](3);
        ps[0] = providerA;
        ps[1] = providerB;
        ps[2] = re;
        vault.setProviders(ps);
        vm.prank(admin);
        vault.setEntryProvider(re);
        vm.prank(admin);
        vault.setMinAssets(1);

        asset.mint(alice, 7);
        vm.startPrank(alice);
        asset.approve(address(vault), 7);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.deposit(7, alice);
        vm.stopPrank();
    }
}
