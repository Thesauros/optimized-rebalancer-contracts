// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockProvider} from "../../contracts/mocks/MockProvider.sol";
import {MockProtocol} from "../../contracts/mocks/MockProtocol.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Test} from "forge-std/Test.sol";
import "../../contracts/libraries/Constants.sol";

contract MockingBase is Test {
    uint8 public constant ASSET_DECIMALS = 6;

    string public constant NAME = "Thesauros MockUSDC";
    string public constant SYMBOL = "tmUSDC";

    uint256 public constant YEAR = 365 days;
    uint256 public constant DAY = 1 days;

    uint256 public constant ONE = 1e6;
    uint256 public constant HUNDRED = 100e6;
    uint256 public constant THOUSAND = 1000e6;

    uint96 public constant FIVE_PERCENT = 0.05e18;
    uint96 public constant TEN_PERCENT = 0.1e18;

    bytes32 public constant ADMIN_ROLE = 0x00;
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public treasury = makeAddr("treasury");

    Rebalancer public implementation;
    TransparentUpgradeableProxy public proxy;
    Rebalancer public vault;

    MockERC20 public asset;

    MockProtocol public mockProtocolA;
    MockProtocol public mockProtocolB;
    MockProtocol public mockProtocolC;
    IProvider public mockProviderA;
    IProvider public mockProviderB;
    IProvider public mockProviderC;
    IProvider[] public providers;

    uint256 public minAssets;

    uint256 public initialTotalSupply;
    uint256 public initialTotalAssets;
    uint256 public maxTestAssets;
    uint256 public maxTestShares;

    function setUp() public virtual {
        asset = new MockERC20(ASSET_DECIMALS);
        vm.label(address(asset), "Underlying");

        mockProtocolA = new MockProtocol(asset);
        mockProtocolB = new MockProtocol(asset);
        mockProtocolC = new MockProtocol(asset);

        vm.label(address(mockProtocolA), "MockProtocolA");
        vm.label(address(mockProtocolB), "MockProtocolB");
        vm.label(address(mockProtocolC), "MockProtocolC");

        mockProviderA = new MockProvider(mockProtocolA);
        mockProviderB = new MockProvider(mockProtocolB);
        mockProviderC = new MockProvider(mockProtocolC);

        vm.label(address(mockProviderA), "MockProviderA");
        vm.label(address(mockProviderB), "MockProviderB");
        vm.label(address(mockProviderC), "MockProviderC");

        providers.push(mockProviderA);
        providers.push(mockProviderB);

        minAssets = ONE;

        (implementation, proxy, vault) = _deployVault();
        _initializeVault(vault);

        vault.grantRole(EXECUTOR_ROLE, address(this));

        // 1:1 price during initial deposit
        initialTotalAssets = minAssets;
        initialTotalSupply = minAssets;

        // very large (assuming 6 underlying decimals)
        maxTestAssets = 1e24;
        maxTestShares = 1e24;
    }

    function _deployVault()
        internal
        returns (Rebalancer, TransparentUpgradeableProxy, Rebalancer)
    {
        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            address(impl),
            address(this), // owner of the proxy admin for testing
            ""
        );
        Rebalancer v = Rebalancer(payable(address(p)));

        return (impl, p, v);
    }

    function _initializeVault(Rebalancer v) internal {
        deal(address(asset), address(this), minAssets);
        asset.approve(address(v), minAssets);

        v.initialize(
            address(this), // admin for testing
            address(this), // timelock for testing
            address(asset),
            NAME,
            SYMBOL,
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
        deal(address(asset), from, amount);

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

        deal(address(asset), from, previewed);

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

    function _getAssetsAtProvider(
        IRebalancer v,
        IProvider provider
    ) internal view returns (uint256) {
        return provider.getDepositBalance(address(v), v);
    }
}
