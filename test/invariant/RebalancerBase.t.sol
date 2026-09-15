// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockProvider} from "../mocks/MockProvider.sol";
import "../../contracts/libraries/Constants.sol";

/**
 * @title RebalancerBase
 * @notice Shared setup/helpers for the mock-based Rebalancer test suite. Deliberately has
 *         NO RPC/fork dependency (unlike `test/forking/ForkingBase.t.sol`) so it runs fast
 *         and deterministically, which is required for invariant/fuzz campaigns.
 * @dev Deploys a vault with three independent `MockProvider`/`MockYieldSource` pairs, each
 *      backed by the same `MockERC20` asset, so tests can exercise multi-provider
 *      aggregation, rebalancing, and per-provider degradation.
 */
contract RebalancerBase is Test {
    uint8 public constant ASSET_DECIMALS = 6;
    uint256 public constant ONE = 1e6;
    uint256 public constant HUNDRED = 100e6;
    uint256 public constant THOUSAND = 1_000e6;
    uint256 public constant MILLION = 1_000_000e6;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public treasury = makeAddr("treasury");
    address public referenceHolder = makeAddr("referenceHolder");

    MockERC20 public asset;

    Rebalancer public vault;

    MockYieldSource public sourceA;
    MockYieldSource public sourceB;
    MockYieldSource public sourceC;

    MockProvider public providerA;
    MockProvider public providerB;
    MockProvider public providerC;

    uint256 public minAssets;
    uint256 public initialTotalSupply;
    uint256 public initialTotalAssets;

    function setUp() public virtual {
        asset = new MockERC20("Mock USD", "mUSD", ASSET_DECIMALS);

        sourceA = new MockYieldSource(asset);
        sourceB = new MockYieldSource(asset);
        sourceC = new MockYieldSource(asset);

        providerA = new MockProvider(sourceA);
        providerB = new MockProvider(sourceB);
        providerC = new MockProvider(sourceC);

        minAssets = ONE;
        // 1:1 price during initial (dead-share) deposit
        initialTotalAssets = minAssets;
        initialTotalSupply = minAssets;

        vault = _deployVault();
        _initializeVault(vault, _defaultProviders());
    }

    function _defaultProviders()
        internal
        view
        returns (IProvider[] memory providers)
    {
        providers = new IProvider[](3);
        providers[0] = providerA;
        providers[1] = providerB;
        providers[2] = providerC;
    }

    function _deployVault() internal returns (Rebalancer) {
        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            address(impl),
            address(this), // owner of the proxy admin for testing
            ""
        );
        return Rebalancer(payable(address(p)));
    }

    function _initializeVault(
        Rebalancer v,
        IProvider[] memory providers
    ) internal {
        asset.mint(address(this), minAssets);
        asset.approve(address(v), minAssets);

        v.initialize(
            address(this), // admin for testing
            address(this), // timelock for testing
            address(asset),
            "Mock Rebalancer",
            "mrTOK",
            providers,
            treasury,
            0,
            0,
            minAssets
        );
    }

    function _executeDeposit(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 shares) {
        asset.mint(from, amount);

        uint256 assetsBefore = asset.balanceOf(from);

        vm.startPrank(from);
        asset.approve(address(v), amount);
        shares = v.deposit(amount, from);
        vm.stopPrank();

        assertEq(asset.balanceOf(from), assetsBefore - amount);
    }

    function _executeMint(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 assets) {
        uint256 previewed = v.previewMint(amount);
        asset.mint(from, previewed);

        uint256 assetsBefore = asset.balanceOf(from);

        vm.startPrank(from);
        asset.approve(address(v), previewed);
        assets = v.mint(amount, from);
        vm.stopPrank();

        assertEq(assets, previewed);
        assertEq(asset.balanceOf(from), assetsBefore - previewed);
    }

    function _executeWithdraw(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 shares) {
        uint256 assetsBefore = asset.balanceOf(from);

        vm.prank(from);
        shares = v.withdraw(amount, from, from);

        assertEq(asset.balanceOf(from), assetsBefore + amount);
    }

    function _executeRedeem(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 assets) {
        uint256 assetsBefore = asset.balanceOf(from);

        vm.prank(from);
        assets = v.redeem(amount, from, from);

        assertEq(asset.balanceOf(from), assetsBefore + assets);
    }

    /// @dev Mints `amount` of `asset` to this test contract, approves `source`, and calls
    /// `simulateYield` so `vault`'s reported balance at `source` grows by `amount`.
    function _simulateYield(MockYieldSource source, uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(source), amount);
        source.simulateYield(address(vault), amount);
    }
}
