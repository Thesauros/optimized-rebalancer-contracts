// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Test} from "forge-std/Test.sol";
import "../../contracts/libraries/Constants.sol";

contract ForkingBase is Test {
    uint256 public constant ONE = 1e6;
    uint256 public constant HUNDRED = 100e6;
    uint256 public constant THOUSAND = 1000e6;

    address public constant USDC_ADDRESS =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDT_ADDRESS =
        0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address public constant COMET_USDC_ADDRESS =
        0xb125E6687d4313864e53df431d5425969c15Eb2F;
    address public constant COMET_USDT_ADDRESS =
        0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07;
    address public constant MORPHO_STEAKHOUSE_HIGH_YIELD_VAULT_ADDRESS =
        0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA;
    address public constant MORPHO_GAUNTLET_CORE_VAULT_ADDRESS =
        0x7e97fa6893871A2751B5fE961978DCCb2c201E65;
    address public constant MORPHO_YEARN_DEGEN_VAULT_ADDRESS =
        0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9;
    address public constant MORPHO_HYPERITHM_VAULT_ADDRESS =
        0x4B6F1C9E5d470b97181786b26da0d0945A7cf027;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public treasury = makeAddr("treasury");

    Rebalancer public vault;

    IERC20Metadata public usdc;
    IERC20Metadata public usdt;

    uint256 public minAssets;

    uint256 public initialTotalSupply;
    uint256 public initialTotalAssets;

    function setUp() public virtual {
        string memory ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");
        vm.createSelectFork(ARBITRUM_RPC_URL);

        usdc = IERC20Metadata(USDC_ADDRESS);
        vm.label(address(usdc), "USDC");

        usdt = IERC20Metadata(USDT_ADDRESS);
        vm.label(address(usdt), "USDT");

        minAssets = ONE;

        // 1:1 price during initial deposit
        initialTotalAssets = minAssets;
        initialTotalSupply = minAssets;
    }

    function _deployVault() internal returns (Rebalancer) {
        Rebalancer impl = new Rebalancer();
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            address(impl),
            address(this), // owner of the proxy admin for testing
            ""
        );
        Rebalancer v = Rebalancer(payable(address(p)));

        return v;
    }

    function _initializeVault(
        Rebalancer v,
        IERC20Metadata asset,
        IProvider[] memory providers
    ) internal {
        string memory name = string.concat("Thesauros ", asset.name());
        string memory symbol = string.concat("t", asset.symbol());

        deal(address(asset), address(this), minAssets);
        asset.approve(address(v), minAssets);

        v.initialize(
            address(this), // admin for testing
            address(this), // timelock for testing
            address(asset),
            name,
            symbol,
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
        address asset = v.asset();
        deal(asset, from, amount);

        uint256 assetsBefore = IERC20Metadata(asset).balanceOf(from);

        vm.startPrank(from);
        IERC20Metadata(asset).approve(address(v), amount);
        shares = v.deposit(amount, from);
        vm.stopPrank();

        assertEq(IERC20Metadata(asset).balanceOf(from), assetsBefore - amount);
    }

    function _executeMint(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 assets) {
        address asset = v.asset();

        uint256 previewed = v.previewMint(amount);

        deal(asset, from, previewed);

        uint256 assetsBefore = IERC20Metadata(asset).balanceOf(from);

        vm.startPrank(from);
        IERC20Metadata(asset).approve(address(v), previewed);
        assets = v.mint(amount, from);
        vm.stopPrank();

        assertEq(assets, previewed);
        assertEq(
            IERC20Metadata(asset).balanceOf(from),
            assetsBefore - previewed
        );
    }

    function _executeWithdraw(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 shares) {
        address asset = v.asset();

        uint256 assetsBefore = IERC20Metadata(asset).balanceOf(from);

        vm.prank(from);
        shares = v.withdraw(amount, from, from);

        assertEq(IERC20Metadata(asset).balanceOf(from), assetsBefore + amount);
    }

    function _executeRedeem(
        IRebalancer v,
        uint256 amount,
        address from
    ) internal returns (uint256 assets) {
        address asset = v.asset();

        uint256 assetsBefore = IERC20Metadata(asset).balanceOf(from);

        vm.prank(from);
        assets = v.redeem(amount, from, from);

        assertEq(IERC20Metadata(asset).balanceOf(from), assetsBefore + assets);
    }
}
