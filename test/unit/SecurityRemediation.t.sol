// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {PausableActions} from "../../contracts/utils/PausableActions.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {ProviderManager} from "../../contracts/utils/ProviderManager.sol";
import {VaultFactory} from "../../contracts/utils/VaultFactory.sol";
import {FeeCapAsset, FeeCapSource} from "./PerformanceFeeCap.t.sol";

contract RemediationSource is FeeCapSource {
    bool public viewFails;
    bool public withdrawalFails;
    uint256 public shortBy;
    constructor(IERC20 a) FeeCapSource(a) {}

    function configure(bool v, bool w, uint256 shortfall) external {
        viewFails = v;
        withdrawalFails = w;
        shortBy = shortfall;
    }

    function reported(address who) external view returns (uint256) {
        require(!viewFails, "view unavailable");
        return balances[who];
    }

    function release(address who, uint256 amount) external {
        require(!withdrawalFails, "illiquid");
        balances[who] -= amount;
        asset.transfer(who, amount > shortBy ? amount - shortBy : 0);
    }
}

contract RemediationProvider is IProvider {
    RemediationSource public source;

    constructor(RemediationSource s) {
        source = s;
        originalSource = s;
    }
    // Simulates an old mutable registry; only view/action configuration is on
    // this ordinary contract. Delegatecalled actions use immutable originalSource.
    RemediationSource private immutable originalSource;

    function setSource(RemediationSource s) external {
        source = s;
    }

    function deposit(uint256 amount, IRebalancer v) external returns (bool) {
        originalSource.creditDeposit(address(v), amount);
        return true;
    }

    function withdraw(uint256 amount, IRebalancer v) external returns (bool) {
        originalSource.release(address(v), amount);
        return true;
    }

    function getDepositBalance(address who, IRebalancer) external view returns (uint256) {
        return source.reported(who);
    }

    function getDepositRate(IRebalancer) external pure returns (uint256) {
        return 0;
    }

    function getSource(address, address, address) external view returns (address) {
        return address(source);
    }

    function getIdentifier() external pure returns (string memory) {
        return "remediation";
    }
}

/// @dev Upgrade fixture models the exact old ERC7201 prefix and inherited
/// token/role namespaces, without the appended security fields. It is a layout
/// fixture, not a claim that arbitrary deployed bytecode has been attested.
contract LegacyAccountingFixture is ERC20PermitUpgradeable, AccessManager, PausableActions {
    struct Layout {
        IERC20Metadata asset;
        uint8 decimals;
        IProvider[] providers;
        IProvider entry;
        address timelock;
        address treasury;
        uint96 managementFee;
        uint96 performanceFee;
        uint256 lastAssets;
        uint64 lastTime;
        uint256 minAssets;
    }
    bytes32 private constant SLOT = 0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;

    function layout() private pure returns (Layout storage s) {
        assembly { s.slot := SLOT }
    }

    constructor() {
        _disableInitializers();
    }

    function pause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _pause(action);
    }

    function unpause(Actions action) external override onlyRole(ADMIN_ROLE) {
        _unpause(action);
    }

    function initialize(address a, IProvider[] calldata ps, address treasury, address holder) external initializer {
        __ERC20_init("Legacy", "LEG");
        __ERC20Permit_init("Legacy");
        __AccessManager_init(msg.sender);
        Layout storage s = layout();
        s.asset = IERC20Metadata(a);
        s.decimals = 6;
        s.providers = ps;
        s.entry = ps[0];
        s.timelock = msg.sender;
        s.treasury = treasury;
        s.managementFee = 1e16;
        s.performanceFee = 25e16;
        s.lastAssets = 1001e6;
        s.lastTime = uint64(block.timestamp);
        s.minAssets = 1e6;
        s.asset.transferFrom(msg.sender, address(this), 1001e6);
        s.asset.approve(ps[0].getSource(a, address(this), address(0)), type(uint256).max);
        RemediationSource(ps[0].getSource(a, address(this), address(0))).creditDeposit(address(this), 1001e6);
        _mint(address(this), 1e6);
        _mint(holder, 1000e6);
    }
}

contract SecurityRemediationTest is Test {
    uint256 constant ONE = 1e6;
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    FeeCapAsset asset;
    RemediationSource sourceA;
    RemediationSource sourceB;
    RemediationProvider providerA;
    RemediationProvider providerB;
    Rebalancer vault;

    function setUp() public {
        asset = new FeeCapAsset();
        sourceA = new RemediationSource(IERC20(address(asset)));
        sourceB = new RemediationSource(IERC20(address(asset)));
        providerA = new RemediationProvider(sourceA);
        providerB = new RemediationProvider(sourceB);
        vault =
            Rebalancer(payable(address(new TransparentUpgradeableProxy(address(new Rebalancer()), address(this), ""))));
        asset.mint(address(this), ONE);
        asset.approve(address(vault), ONE);
        vault.initialize(
            address(this), address(this), address(asset), "secure", "SEC", _providers(), treasury, 0, 0, ONE
        );
        vault.grantRole(vault.EXECUTOR_ROLE(), address(this));
        _deposit(alice, 1000 * ONE);
    }

    function _providers() internal view returns (IProvider[] memory ps) {
        ps = new IProvider[](2);
        ps[0] = providerA;
        ps[1] = providerB;
    }

    function _deposit(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _move(uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        IProvider[] memory from = new IProvider[](1);
        from[0] = providerA;
        IProvider[] memory to = new IProvider[](1);
        to[0] = providerB;
        vault.rebalance(amounts, from, to);
    }

    function _yield(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(sourceA), amount);
        sourceA.simulateYield(address(vault), amount);
    }

    function testFundedUnknownNavBlocksConversionsFeesAndAllSettlements() public {
        _move(400 * ONE);
        uint256 supply = vault.totalSupply();
        uint256 baseline = vault.getLastTotalAssets();
        uint256 hwm = vault.getHighWaterMark();
        sourceB.configure(true, false, 0);
        assertFalse(vault.providersHealthy());
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.totalAssets();
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.previewRedeem(100 * ONE);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.applyFees();
        vm.startPrank(alice);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.redeem(100 * ONE, alice, alice);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.withdraw(100 * ONE, alice, alice);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.deposit(ONE, alice);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.mint(ONE, alice);
        vm.stopPrank();
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.getLastTotalAssets(), baseline);
        assertEq(vault.getHighWaterMark(), hwm);
        assertEq(vault.balanceOf(treasury), 0);
        sourceB.configure(false, false, 0);
        vm.prank(alice);
        vault.withdraw(100 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 100 * ONE);
    }

    function testKnownNavUsesLaterLiquidSourceAfterFirstWithdrawalReverts() public {
        _move(600 * ONE);
        sourceA.configure(false, true, 0);
        assertTrue(vault.providersHealthy());
        vm.prank(alice);
        vault.withdraw(100 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 100 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 500 * ONE);
    }

    function testMeasuredShortReceiptUsesOtherProviderAndInsufficientLiquidityIsAtomic() public {
        _move(200 * ONE);
        sourceA.configure(false, false, 1);
        vm.prank(alice);
        vault.withdraw(100 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 100 * ONE);
        assertEq(sourceB.balanceOf(address(vault)), 200 * ONE - 1);
        sourceA.configure(false, true, 0);
        sourceB.configure(false, true, 0);
        uint256 shares = vault.balanceOf(alice);
        uint256 assetsBefore = vault.totalAssets();
        vm.prank(alice);
        vm.expectRevert(IRebalancer.InsufficientLiquidity.selector);
        vault.withdraw(ONE, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), assetsBefore);
    }

    function testHighWaterMarkSurvivesLossCapitalFlowsAndRecovery() public {
        vault.setPerformanceFee(25e16);
        _yield(100 * ONE);
        vault.applyFees();
        uint256 feeShares = vault.balanceOf(treasury);
        uint256 peak = vault.getHighWaterMark();
        sourceA.debitAndSend(address(vault), 200 * ONE, address(this));
        vault.applyFees();
        _deposit(bob, 100 * ONE);
        vm.prank(alice);
        vault.withdraw(100 * ONE, alice, alice);
        assertEq(vault.getHighWaterMark(), peak);
        _yield(150 * ONE);
        vault.applyFees();
        assertEq(vault.balanceOf(treasury), feeShares, "new capital and recovery below PPS peak are not performance");
        _yield(200 * ONE);
        vault.applyFees();
        assertGt(vault.balanceOf(treasury), feeShares, "genuine new per-share peak is charged");
        assertGe(vault.getHighWaterMark(), peak);
    }

    function testLongInactivityKeepsFeesSettersDepositsAndExitsDefined() public {
        vault.setManagementFee(5e16);
        vault.setPerformanceFee(25e16);
        vm.warp(block.timestamp + 50 * 365 days);
        vault.getAccruedFees();
        vault.applyFees();
        assertGt(vault.totalSupply(), 0);
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        _deposit(bob, ONE);
        vm.prank(treasury);
        vault.withdraw(ONE, treasury, treasury);
        assertEq(asset.balanceOf(treasury), ONE);
    }

    function testDuplicateProvidersAliasesAndFundedOrUnreadableRemovalRejected() public {
        IProvider[] memory ps = new IProvider[](2);
        ps[0] = providerA;
        ps[1] = providerA;
        vm.expectRevert(IRebalancer.DuplicateProviderSource.selector);
        vault.setProviders(ps);
        ps[1] = new RemediationProvider(sourceA);
        vm.expectRevert(IRebalancer.DuplicateProviderSource.selector);
        vault.setProviders(ps);
        _move(1);
        IProvider[] memory onlyA = new IProvider[](1);
        onlyA[0] = providerA;
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderHasAssets.selector, address(providerB), 1));
        vault.setProviders(onlyA);
        sourceB.configure(true, false, 0);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.setProviders(onlyA);
        sourceB.configure(false, false, 0);
        sourceB.debitAndSend(address(vault), 1, address(this));
        vault.setProviders(onlyA);
        assertEq(asset.allowance(address(vault), address(sourceB)), 0);
        assertEq(vault.getPinnedProviderSource(providerB), address(0));
    }

    function testSourceRetargetFailsClosedWithoutApprovingNewSource() public {
        RemediationSource replacement = new RemediationSource(IERC20(address(asset)));
        providerA.setSource(replacement);
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        vault.totalAssets();
        vm.expectRevert(IRebalancer.ProviderSourceChanged.selector);
        vault.setProviders(_providers());
        assertEq(vault.getPinnedProviderSource(providerA), address(sourceA));
        assertEq(asset.allowance(address(vault), address(replacement)), 0);
    }

    function testRegistrySourceIsWriteOnceAndIdempotentForBothMaps() public {
        ProviderManager registry = new ProviderManager(address(this));
        registry.setYieldToken("Compound_V3_Provider", address(asset), address(sourceA));
        registry.setYieldToken("Compound_V3_Provider", address(asset), address(sourceA));
        vm.expectRevert(ProviderManager.SourceAlreadyConfigured.selector);
        registry.setYieldToken("Compound_V3_Provider", address(asset), address(sourceB));
        registry.setMarket("pair", address(asset), alice, address(sourceA));
        vm.expectRevert(ProviderManager.SourceAlreadyConfigured.selector);
        registry.setMarket("pair", address(asset), alice, address(sourceB));
        assertEq(registry.getYieldToken("Compound_V3_Provider", address(asset)), address(sourceA));
    }

    function testFactoryReturnsInitializedProxyWithNoSecondInitializer() public {
        VaultFactory factory = new VaultFactory();
        asset.mint(address(this), ONE);
        asset.approve(address(factory), ONE);
        bytes memory data = abi.encodeCall(
            Rebalancer.initialize,
            (
                address(this),
                address(this),
                address(asset),
                "factory",
                "FAC",
                _providers(),
                treasury,
                uint96(0),
                uint96(0),
                ONE
            )
        );
        Rebalancer v = Rebalancer(
            payable(factory.deployAndInitialize(
                    address(new Rebalancer()), address(this), address(this), IERC20(address(asset)), ONE, data
                ))
        );
        assertEq(v.getHighWaterMark(), 1e18);
        assertEq(v.totalAssets(), ONE);
        assertTrue(v.hasRole(v.ADMIN_ROLE(), address(this)));
        vm.prank(bob);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(bob, bob, address(asset), "bad", "BAD", _providers(), bob, 0, 0, ONE);
    }

    function testFactoryRejectsAliasedSourcesDuringInitialization() public {
        VaultFactory factory = new VaultFactory();
        asset.mint(address(this), ONE);
        asset.approve(address(factory), ONE);
        IProvider[] memory ps = new IProvider[](2);
        ps[0] = providerA;
        ps[1] = new RemediationProvider(sourceA);
        bytes memory data = abi.encodeCall(
            Rebalancer.initialize,
            (address(this), address(this), address(asset), "alias", "BAD", ps, treasury, uint96(0), uint96(0), ONE)
        );
        Rebalancer implementation = new Rebalancer();
        vm.expectRevert(IRebalancer.DuplicateProviderSource.selector);
        factory.deployAndInitialize(
            address(implementation), address(this), address(this), IERC20(address(asset)), ONE, data
        );
        assertEq(asset.balanceOf(address(this)), ONE, "failed atomic creation leaves seed untouched");
    }

    function testLegacyUpgradeBootstrapsAtomicallyAndPreservesCoreTokenAndRoleStorage() public {
        LegacyAccountingFixture implementation = new LegacyAccountingFixture();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), address(this), "");
        LegacyAccountingFixture legacy = LegacyAccountingFixture(address(proxy));
        asset.mint(address(this), 1001 * ONE);
        asset.approve(address(legacy), 1001 * ONE);
        legacy.initialize(address(asset), _providers(), treasury, alice);
        vm.prank(alice);
        legacy.approve(bob, 77);
        legacy.grantRole(legacy.EXECUTOR_ROLE(), bob);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(new Rebalancer()),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (uint256(1e18)))
        );
        Rebalancer upgraded = Rebalancer(payable(address(proxy)));
        assertEq(upgraded.asset(), address(asset));
        assertEq(upgraded.decimals(), 6);
        assertEq(upgraded.totalSupply(), 1001 * ONE);
        assertEq(upgraded.balanceOf(alice), 1000 * ONE);
        assertEq(upgraded.allowance(alice, bob), 77);
        assertEq(upgraded.name(), "Legacy");
        assertTrue(upgraded.hasRole(upgraded.ADMIN_ROLE(), address(this)));
        assertTrue(upgraded.hasRole(upgraded.EXECUTOR_ROLE(), bob));
        assertEq(upgraded.getManagementFee(), 1e16);
        assertEq(upgraded.getPerformanceFee(), 25e16);
        assertEq(upgraded.getTreasury(), treasury);
        assertEq(upgraded.getTimelock(), address(this));
        assertEq(upgraded.getLastTotalAssets(), 1001 * ONE);
        assertEq(upgraded.getMinAssets(), ONE);
        assertEq(upgraded.getHighWaterMark(), 1e18);
        assertEq(upgraded.getPinnedProviderSource(providerA), address(sourceA));
        assertEq(upgraded.previewRedeem(100 * ONE), 100 * ONE);
        vm.prank(alice);
        upgraded.withdraw(100 * ONE, alice, alice);
        assertEq(asset.balanceOf(alice), 100 * ONE);
    }

    function testBootstrapRejectsPublicCallerAndLowHistoricalMark() public {
        LegacyAccountingFixture legacy = LegacyAccountingFixture(
            address(new TransparentUpgradeableProxy(address(new LegacyAccountingFixture()), address(this), ""))
        );
        asset.mint(address(this), 1001 * ONE);
        asset.approve(address(legacy), 1001 * ONE);
        legacy.initialize(address(asset), _providers(), treasury, alice);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(legacy), ADMIN_SLOT)))));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(legacy)), address(new Rebalancer()), "");
        Rebalancer upgraded = Rebalancer(payable(address(legacy)));
        vm.prank(bob);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        upgraded.initializeSecurityAccounting(1e18);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        upgraded.initializeSecurityAccounting(1e18 - 1);
        upgraded.initializeSecurityAccounting(12e17);
        assertEq(upgraded.getHighWaterMark(), 12e17);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        upgraded.initializeSecurityAccounting(12e17);
    }
}
