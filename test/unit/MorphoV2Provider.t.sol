// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Id, Market, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoV2Provider} from "../../contracts/providers/MorphoV2Provider.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";

contract V2TestAsset is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev V2-shaped double: zero max* views do not prevent native actions; previews
///      account for pending dilution and virtual shares. Fork tests cover the
///      actual Morpho implementation independently of this model.
contract V2TestVault is ERC4626 {
    address[] public adapters;
    uint64 public maxRate = uint64(uint256(1e18) / 365 days);
    uint96 public performanceFee;
    uint96 public managementFee;
    uint256 public performanceFeeShares;
    uint256 public managementFeeShares;
    uint256 private _assets;
    bool public blockedDeposits;
    bool public blockedWithdrawals;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Morpho V2", "mv2") {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function adaptersLength() external view returns (uint256) {
        return adapters.length;
    }

    function addAdapter(address adapter) external {
        adapters.push(adapter);
    }

    function setAssets(uint256 assets) external {
        _assets = assets;
    }

    function totalAssets() public view override returns (uint256) {
        return _assets;
    }

    function setFees(uint96 performance, uint96 management) external {
        performanceFee = performance;
        managementFee = management;
    }

    function setPendingFees(uint256 performance, uint256 management) external {
        performanceFeeShares = performance;
        managementFeeShares = management;
    }

    function setMaxRate(uint64 rate) external {
        maxRate = rate;
    }

    function setBlocked(bool deposits, bool withdrawals) external {
        blockedDeposits = deposits;
        blockedWithdrawals = withdrawals;
    }

    function accrueInterestView() external view returns (uint256, uint256, uint256) {
        return (_assets, performanceFeeShares, managementFeeShares);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return
            Math.mulDiv(
                shares, _assets + 1, totalSupply() + performanceFeeShares + managementFeeShares + 1e12, rounding
            );
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return
            Math.mulDiv(
                assets, totalSupply() + performanceFeeShares + managementFeeShares + 1e12, _assets + 1, rounding
            );
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        require(!blockedDeposits, "deposit gated");
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        _assets += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(!blockedWithdrawals, "withdraw gated");
        shares = previewWithdraw(assets);
        _assets -= assets;
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }
}

contract V2UnknownAdapter {
    uint256 public immutable realAssets;

    constructor(uint256 assets) {
        realAssets = assets;
    }
}

contract V2VaultAdapter {
    address public immutable morphoVaultV1;
    uint256 public immutable realAssets;

    constructor(address underlying, uint256 assets) {
        morphoVaultV1 = underlying;
        realAssets = assets;
    }
}

/// @dev A different adapter family may expose morpho() without the market ABI.
contract V2IncompleteMarketAdapter {
    address public immutable morpho;
    uint256 public constant realAssets = 100e6;

    constructor(address morpho_) {
        morpho = morpho_;
    }
}

contract V2GasBurningRateAdapter {
    uint256 public constant realAssets = 100e6;

    function morpho() external pure returns (address) {
        while (true) {}
    }
}

contract V2MarketAdapter {
    address public immutable morpho;
    bytes32[] public marketIds;
    uint256 public immutable realAssets;
    uint256 public immutable expectedAssets;

    constructor(address morpho_, bytes32 id, uint256 assets) {
        morpho = morpho_;
        marketIds.push(id);
        realAssets = assets;
        expectedAssets = assets;
    }

    function marketIdsLength() external view returns (uint256) {
        return marketIds.length;
    }

    function expectedSupplyAssets(bytes32) external view returns (uint256) {
        return expectedAssets;
    }
}

/// @dev Plain delegatecall harness verifies context checks and revert propagation.
contract V2ProviderCaller {
    address public immutable asset;
    uint256 public sentinel = 123456;

    constructor(address asset_) {
        asset = asset_;
    }

    function execute(address provider, bytes calldata data) external {
        (bool ok, bytes memory reason) = provider.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }

    function approve(address source) external {
        IERC20(asset).approve(source, type(uint256).max);
    }
}

contract MorphoV2ProviderTest is Test {
    using MarketParamsLib for MarketParams;

    V2TestAsset internal usdc;
    V2TestVault internal source;
    MorphoV2Provider internal provider;
    Rebalancer internal vault;
    address internal alice = makeAddr("alice");
    address internal morpho = makeAddr("morpho");
    address internal irm = makeAddr("irm");
    address internal underlying = makeAddr("underlying-v1");
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BORROW_RATE = 3_170_979_198; // ~10% APR per second, wad

    function setUp() public {
        usdc = new V2TestAsset();
        source = new V2TestVault(usdc);
        provider = new MorphoV2Provider(address(source));
        vault = _newRebalancer(usdc, provider);
    }

    function _newRebalancer(V2TestAsset asset, IProvider entry) internal returns (Rebalancer v) {
        Rebalancer impl = new Rebalancer();
        v = Rebalancer(payable(address(new TransparentUpgradeableProxy(address(impl), address(this), ""))));
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = entry;
        asset.mint(address(this), 1e6);
        asset.approve(address(v), 1e6);
        v.initialize(
            address(this),
            address(this),
            address(asset),
            "Rebalancer",
            "rUSD",
            providers,
            makeAddr("treasury"),
            0,
            0,
            1e6
        );
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function testLifecycleThroughRebalancerWithZeroMaxViews() public {
        assertEq(source.maxDeposit(address(vault)), 0);
        assertEq(source.maxWithdraw(address(vault)), 0);
        uint256 shares = _deposit(1_000e6);
        assertEq(source.balanceOf(address(provider)), 0);
        assertEq(source.balanceOf(alice), 0);
        assertGt(source.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), 1_001e6);
        assertTrue(vault.providersHealthy());
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(vault.totalAssets(), 1e6);
        assertEq(vault.asset(), address(usdc));
    }

    function testIdentifierAndApprovalSource() public view {
        assertEq(provider.getIdentifier(), "Morpho_V2_Provider");
        assertEq(provider.getSource(address(0), alice, address(vault)), address(source));
        assertEq(usdc.allowance(address(vault), address(source)), type(uint256).max);
    }

    function testBalanceIncludesPendingFeesAndVirtualShares() public {
        _deposit(1_000e6);
        source.setAssets(1_101e6);
        source.setPendingFees(10e18, 20e18);
        uint256 shares = source.balanceOf(address(vault));
        uint256 expected = Math.mulDiv(shares, 1_101e6 + 1, source.totalSupply() + 30e18 + 1e12);
        assertEq(provider.getDepositBalance(address(vault), vault), expected);
        assertLt(expected, Math.mulDiv(shares, source.totalAssets(), source.totalSupply()));
    }

    function testBalanceRecognizesLossAndIgnoresLiquidity() public {
        _deposit(1_000e6);
        uint256 beforeLoss = provider.getDepositBalance(address(vault), vault);
        source.setAssets(800e6);
        // Market liquidity is not a cap on NAV.
        deal(address(usdc), address(source), 0);
        uint256 expected = source.previewRedeem(source.balanceOf(address(vault)));
        assertLt(expected, beforeLoss);
        assertEq(provider.getDepositBalance(address(vault), vault), expected);
    }

    function testEmptyPositionDoesNotCallPreview() public {
        vm.mockCallRevert(address(source), abi.encodeWithSignature("previewRedeem(uint256)", 0), "broken");
        assertEq(provider.getDepositBalance(alice, vault), 0);
    }

    function testRevertingValuationMarksVaultUnhealthy() public {
        vm.mockCallRevert(address(source), abi.encodeWithSignature("previewRedeem(uint256)"), "broken");
        assertFalse(vault.providersHealthy());
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.deposit(1e6, alice);
        vm.stopPrank();
    }

    function testRejectsDirectActions() public {
        vm.expectRevert(MorphoV2Provider.InvalidVaultContext.selector);
        provider.deposit(1, vault);
        vm.expectRevert(MorphoV2Provider.InvalidVaultContext.selector);
        provider.withdraw(1, vault);
    }

    function testRejectsWrongContextAndAsset() public {
        V2ProviderCaller caller = new V2ProviderCaller(address(new V2TestAsset()));
        vm.expectRevert(MorphoV2Provider.AssetMismatch.selector);
        caller.execute(address(provider), abi.encodeCall(IProvider.deposit, (1, IRebalancer(address(caller)))));
        vm.expectRevert(MorphoV2Provider.InvalidVaultContext.selector);
        caller.execute(address(provider), abi.encodeCall(IProvider.withdraw, (1, IRebalancer(alice))));
        assertEq(caller.sentinel(), 123456);
    }

    function testNativeGateAndLiquidityFailuresPropagate() public {
        V2ProviderCaller caller = new V2ProviderCaller(address(usdc));
        caller.approve(address(source));
        usdc.mint(address(caller), 10e6);
        source.setBlocked(true, false);
        vm.expectRevert("deposit gated");
        caller.execute(address(provider), abi.encodeCall(IProvider.deposit, (10e6, IRebalancer(address(caller)))));
        source.setBlocked(false, false);
        caller.execute(address(provider), abi.encodeCall(IProvider.deposit, (10e6, IRebalancer(address(caller)))));
        source.setBlocked(false, true);
        vm.expectRevert("withdraw gated");
        caller.execute(address(provider), abi.encodeCall(IProvider.withdraw, (1e6, IRebalancer(address(caller)))));
        source.setBlocked(false, false);
        deal(address(usdc), address(source), 0);
        vm.expectRevert();
        caller.execute(address(provider), abi.encodeCall(IProvider.withdraw, (1e6, IRebalancer(address(caller)))));
        assertEq(caller.sentinel(), 123456);
        assertEq(provider.getDepositBalance(address(caller), vault), 10e6);
    }

    function testRejectsNonVaultAndV1AtConstruction() public {
        vm.expectRevert(MorphoV2Provider.InvalidMorphoVault.selector);
        new MorphoV2Provider(address(0));
        vm.expectRevert();
        new MorphoV2Provider(address(usdc));
    }

    function _mockMarket(uint256 supply, uint256 borrow, uint256 fee, address model) internal returns (Id id) {
        MarketParams memory params =
            MarketParams(address(usdc), makeAddr("collateral"), makeAddr("oracle"), model, 0.8e18);
        id = params.id();
        Market memory market = Market(
            uint128(supply),
            uint128(supply * 1e6),
            uint128(borrow),
            uint128(borrow * 1e6),
            uint128(block.timestamp),
            uint128(fee)
        );
        vm.mockCall(morpho, abi.encodeWithSignature("idToMarketParams(bytes32)", id), abi.encode(params));
        vm.mockCall(morpho, abi.encodeWithSignature("market(bytes32)", id), abi.encode(market));
        vm.mockCall(
            irm,
            abi.encodeWithSignature(
                "borrowRateView((address,address,address,address,uint256),(uint128,uint128,uint128,uint128,uint128,uint128))"
            ),
            abi.encode(BORROW_RATE)
        );
    }

    function _addMarketAdapter(uint256 assets, uint256 supply, uint256 borrow, uint256 fee, address model) internal {
        Id id = _mockMarket(supply, borrow, fee, model);
        source.addAdapter(address(new V2MarketAdapter(morpho, Id.unwrap(id), assets)));
    }

    function testMarketAdapterRateUsesRayAndProtocolFee() public {
        source.setAssets(1_000e6);
        _addMarketAdapter(1_000e6, 2_000e6, 1_000e6, 0.1e18, irm);
        uint256 expected = Math.mulDiv(BORROW_RATE * YEAR * 1e9 / 2, 0.9e18, 1e18);
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRateIncludesIdleAndUnknownAdapterDilution() public {
        source.setAssets(1_000e6);
        _addMarketAdapter(400e6, 2_000e6, 1_000e6, 0, irm);
        source.addAdapter(address(new V2UnknownAdapter(500e6)));
        assertEq(provider.getDepositRate(vault), Math.mulDiv(BORROW_RATE * YEAR * 1e9 / 2, 400, 1000));
    }

    function testRateAppliesAccrualCeilingAndBothV2Fees() public {
        source.setAssets(1_000e6);
        _addMarketAdapter(1_000e6, 1_000e6, 1_000e6, 0, irm);
        uint64 cap = uint64(uint256(0.04e18) / YEAR);
        uint96 management = uint96(uint256(0.01e18) / YEAR);
        source.setMaxRate(cap);
        source.setFees(0.2e18, management);
        uint256 expected = Math.mulDiv(uint256(cap) * YEAR * 1e9, 0.8e18, 1e18) - uint256(management) * YEAR * 1e9;
        assertEq(provider.getDepositRate(vault), expected);
        source.setFees(0.2e18, uint96(uint256(0.2e18) / YEAR));
        assertEq(provider.getDepositRate(vault), 0);
    }

    function _healthyWeightedRate() internal returns (uint256) {
        source.setAssets(1_000e6);
        _addMarketAdapter(900e6, 2_000e6, 1_000e6, 0, irm);
        return provider.getDepositRate(vault);
    }

    function testRateIsolatesIncompleteMarketAdapter() public {
        uint256 expected = _healthyWeightedRate();
        source.addAdapter(address(new V2IncompleteMarketAdapter(morpho)));
        assertEq(provider.getDepositRate(vault), expected);
        assertTrue(vault.providersHealthy());
    }

    function testRateIsolatesIncompleteVaultV1Adapter() public {
        uint256 expected = _healthyWeightedRate();
        source.addAdapter(address(new V2VaultAdapter(address(usdc), 100e6)));
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRateIsolatesMalformedAdapterMetadata() public {
        uint256 expected = _healthyWeightedRate();
        address adapter = address(new V2IncompleteMarketAdapter(morpho));
        source.addAdapter(adapter);
        vm.mockCall(adapter, abi.encodeWithSignature("morpho()"), hex"01");
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRateIsolatesRevertingAdapterAssets() public {
        uint256 expected = _healthyWeightedRate();
        address adapter = address(new V2UnknownAdapter(100e6));
        source.addAdapter(adapter);
        vm.mockCallRevert(adapter, abi.encodeWithSignature("realAssets()"), "broken rate assets");
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRateIsolatesRevertingIrm() public {
        uint256 expected = _healthyWeightedRate();
        address badIrm = makeAddr("bad-irm");
        _addMarketAdapter(100e6, 2_000e6, 1_000e6, 0, badIrm);
        vm.mockCallRevert(
            badIrm,
            abi.encodeWithSignature(
                "borrowRateView((address,address,address,address,uint256),(uint128,uint128,uint128,uint128,uint128,uint128))"
            ),
            "broken irm"
        );
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRateIsolatesGasExhaustingAdapter() public {
        uint256 expected = _healthyWeightedRate();
        source.addAdapter(address(new V2GasBurningRateAdapter()));
        // A bad adapter must leave enough gas to process healthy ones after it.
        _addMarketAdapter(100e6, 2_000e6, 1_000e6, 0, irm);
        assertEq(provider.getDepositRate{gas: 4_000_000}(vault), expected + expected / 9);
    }

    function testRateIsolatesWeightedContributionOverflow() public {
        uint256 expected = _healthyWeightedRate();
        _addMarketAdapter(type(uint256).max, 2_000e6, 1_000e6, 0, irm);
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testRatePropagatesNativeValuationFailure() public {
        vm.mockCallRevert(address(source), abi.encodeWithSignature("totalAssets()"), "native valuation failed");
        vm.expectRevert("native valuation failed");
        provider.getDepositRate(vault);
    }

    function testZeroRateForIdleEmptyAndZeroBorrowMarkets() public {
        assertEq(provider.getDepositRate(vault), 0);
        source.setAssets(0);
        assertEq(provider.getDepositRate(vault), 0);
        source.setAssets(1_000e6);
        _addMarketAdapter(1_000e6, 1_000e6, 0, 0, irm);
        assertEq(provider.getDepositRate(vault), 0);
    }

    function testZeroRateWithNoIrm() public {
        source.setAssets(1_000e6);
        _addMarketAdapter(1_000e6, 1_000e6, 500e6, 0, address(0));
        assertEq(provider.getDepositRate(vault), 0);
    }

    function testVaultV1AdapterRateIncludesUnderlyingFee() public {
        Id id = _mockMarket(1_000e6, 500e6, 0, irm);
        vm.mockCall(underlying, abi.encodeWithSignature("MORPHO()"), abi.encode(morpho));
        vm.mockCall(underlying, abi.encodeWithSignature("totalAssets()"), abi.encode(1_000e6));
        vm.mockCall(underlying, abi.encodeWithSignature("withdrawQueueLength()"), abi.encode(1));
        vm.mockCall(underlying, abi.encodeWithSignature("withdrawQueue(uint256)", 0), abi.encode(id));
        vm.mockCall(underlying, abi.encodeWithSignature("fee()"), abi.encode(uint96(0.1e18)));
        bytes32[] memory shares = new bytes32[](1);
        shares[0] = bytes32(uint256(1_000e6 * 1e6));
        vm.mockCall(morpho, abi.encodeWithSignature("extSloads(bytes32[])"), abi.encode(shares));
        source.setAssets(1_000e6);
        source.addAdapter(address(new V2VaultAdapter(underlying, 1_000e6)));
        uint256 expected = Math.mulDiv(BORROW_RATE * YEAR * 1e9 / 2, 0.9e18, 1e18);
        assertEq(provider.getDepositRate(vault), expected);
    }

    function testFuzzBalanceMatchesNativePreview(uint96 assets, uint64 feeShares) public {
        assets = uint96(bound(assets, 1e6, 1e18));
        _deposit(assets);
        source.setPendingFees(feeShares, feeShares);
        assertEq(
            provider.getDepositBalance(address(vault), vault), source.previewRedeem(source.balanceOf(address(vault)))
        );
    }
}
