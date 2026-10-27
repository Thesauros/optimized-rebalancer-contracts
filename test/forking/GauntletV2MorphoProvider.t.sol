// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MorphoProvider} from "../../contracts/providers/MorphoProvider.sol";
import {MorphoV2Provider} from "../../contracts/providers/MorphoV2Provider.sol";
import {IMorphoVaultV2} from "../../contracts/interfaces/morpho/IMorphoVaultV2.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";

abstract contract GauntletV2ForkTest is Test {
    IERC20 internal usdc;
    MorphoV2Provider internal provider;
    MorphoProvider internal v1Provider;
    IMorphoVaultV2 internal source;
    Rebalancer internal vault;
    address internal alice = makeAddr("alice");

    function _config() internal view virtual returns (string memory rpc, address asset, address v2, address v1);

    function setUp() public {
        (string memory rpc, address asset, address v2, address v1) = _config();
        vm.createSelectFork(rpc);
        usdc = IERC20(asset);
        source = IMorphoVaultV2(v2);
        provider = new MorphoV2Provider(v2);
        v1Provider = new MorphoProvider(v1);
        Rebalancer impl = new Rebalancer();
        vault = Rebalancer(payable(address(new TransparentUpgradeableProxy(address(impl), address(this), ""))));
        IProvider[] memory providers = new IProvider[](2);
        providers[0] = provider;
        providers[1] = v1Provider;
        deal(asset, address(this), 1e6);
        usdc.approve(address(vault), 1e6);
        vault.initialize(
            address(this),
            address(this),
            asset,
            "Gauntlet V2 Rebalancer",
            "gvr",
            providers,
            makeAddr("treasury"),
            0,
            0,
            1e6
        );
        vault.grantRole(keccak256("EXECUTOR_ROLE"), address(this));
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(address(usdc), alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function testNativeZeroMaxViewsAndPositiveRate() public view {
        assertEq(source.asset(), address(usdc));
        assertEq(source.maxDeposit(address(vault)), 0);
        assertEq(source.maxWithdraw(address(vault)), 0);
        assertEq(source.maxRedeem(address(vault)), 0);
        assertGt(provider.getDepositRate(vault), 0);
        assertEq(provider.getIdentifier(), "Morpho_V2_Provider");
        assertTrue(vault.providersHealthy());
    }

    function testDepositWithdrawAndRedeem() public {
        uint256 shares = _deposit(1_000e6);
        assertGt(source.balanceOf(address(vault)), 0);
        assertEq(source.balanceOf(address(provider)), 0);
        assertEq(
            provider.getDepositBalance(address(vault), vault), source.previewRedeem(source.balanceOf(address(vault)))
        );
        vm.prank(alice);
        uint256 burned = vault.withdraw(100e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100e6);
        vm.prank(alice);
        uint256 received = vault.redeem(shares - burned, alice, alice);
        assertApproxEqAbs(received, 900e6, 5);
        assertEq(vault.balanceOf(alice), 0);
        assertTrue(vault.providersHealthy());
    }

    function testPositionValuationAfterTime() public {
        _deposit(1_000e6);
        skip(1 days);
        vm.roll(block.number + 1);
        assertEq(
            provider.getDepositBalance(address(vault), vault), source.previewRedeem(source.balanceOf(address(vault)))
        );
        assertTrue(vault.providersHealthy());
    }

    function testRebalanceBetweenV1AndV2() public {
        _deposit(1_000e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        IProvider[] memory from = new IProvider[](1);
        IProvider[] memory to = new IProvider[](1);
        from[0] = provider;
        to[0] = v1Provider;
        vault.rebalance(amounts, from, to);
        uint256 v1Balance = v1Provider.getDepositBalance(address(vault), vault);
        assertApproxEqAbs(v1Balance, 100e6, 5);
        // Keep a few atomic units for V1's conservative loss/fee-aware rounding.
        amounts[0] = v1Balance - 5;
        from[0] = v1Provider;
        to[0] = provider;
        vault.rebalance(amounts, from, to);
        assertApproxEqAbs(provider.getDepositBalance(address(vault), vault), 1_001e6, 20);
        assertTrue(vault.providersHealthy());
    }
}

contract GauntletV2BaseForkTest is GauntletV2ForkTest {
    function _config() internal view override returns (string memory, address, address, address) {
        return (
            vm.envString("BASE_RPC_URL"),
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            0x050cE30b927Da55177A4914EC73480238BAD56f0,
            0xc0c5689e6f4D256E861F65465b691aeEcC0dEb12
        );
    }
}

contract GauntletV2EthereumForkTest is GauntletV2ForkTest {
    function _config() internal view override returns (string memory, address, address, address) {
        return (
            vm.envString("ETHEREUM_RPC_URL"),
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0,
            0xdd0f28e19C1780eb6396170735D45153D261490d
        );
    }
}
