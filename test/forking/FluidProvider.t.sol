// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {FluidProvider} from "../../contracts/providers/FluidProvider.sol";
import {IFluidFToken} from "../../contracts/interfaces/fluid/IFluid.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {ForkPins} from "./ForkPins.sol";

/**
 * FluidProvider over fUSDC on Ethereum, the fToken registry `mainnet.strategy.fluidFToken`
 * names. Needs ETHEREUM_RPC_URL; skipped without it.
 */
contract FluidProviderEthereumForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant FUSDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    /// the deployed Ethereum MorphoProvider over Steakhouse USDC, the strategy's entry provider
    IProvider internal constant STEAKHOUSE = IProvider(0x4C7e55689aCcC42562E113e04c3BDe1B2eb76622);
    address internal constant STEAKHOUSE_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /**
     * Tolerance on the Fluid leg, in USDC micro-units.
     *
     * A 10_000 USDC deposit reads back a fraction over 10_001 and each assertion below is
     * written against that rounded figure, so the gap the tolerance has to cover is the
     * rounding plus the drift of `previewRedeem`, which reprices against an exchange price
     * that accrues every block. Measured on mainnet: 6000999997 and 6000999998 across
     * blocks 26_100_000..26_390_000 — up to 3 below the round 6_001e6. A tolerance of 2 was
     * narrower than the author's own rounding, so the assertion went red once the chain
     * moved past the block it was calibrated on.
     *
     * 1e2 is 0.0001 USDC: two orders of magnitude above that drift, and still 10_000x
     * tighter than the 1 USDC error these assertions exist to catch.
     */
    uint256 internal constant FLUID_TOLERANCE = 1e2;

    IERC20 internal usdc = IERC20(USDC);
    IFluidFToken internal fToken = IFluidFToken(FUSDC);
    FluidProvider internal provider;
    Rebalancer internal vault;
    address internal alice = makeAddr("alice");
    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        ForkPins.selectFork(vm, url, ForkPins.ETHEREUM_VAR, ForkPins.ETHEREUM);
        forked = true;

        provider = new FluidProvider(FUSDC);
        Rebalancer impl = new Rebalancer();
        vault = Rebalancer(payable(address(new TransparentUpgradeableProxy(address(impl), address(this), ""))));
        IProvider[] memory providers = new IProvider[](2);
        providers[0] = provider;
        providers[1] = STEAKHOUSE;
        deal(USDC, address(this), 1e6);
        usdc.approve(address(vault), 1e6);
        vault.initialize(
            address(this), address(this), USDC, "Fluid Rebalancer", "flr", providers, makeAddr("treasury"), 0, 0, 1e6
        );
        vault.grantRole(keccak256("EXECUTOR_ROLE"), address(this));
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(USDC, alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function testWiring() public view {
        if (!forked) return;
        assertEq(address(provider.fToken()), FUSDC);
        assertEq(address(provider.liquidity()), LIQUIDITY, "Liquidity layer from fToken.getData()");
        assertEq(provider.getSource(USDC, address(vault), address(0)), FUSDC);
        assertEq(provider.getIdentifier(), "Fluid_Provider");
        assertEq(vault.getPinnedProviderSource(provider), FUSDC, "source pinned");
        assertTrue(vault.providersHealthy());
    }

    function testConstructorRejectsAnythingButAnFToken() public {
        if (!forked) return;
        // not makeAddr("eoa"): its key is public, and on mainnet it carries an EIP-7702 delegation
        address empty = makeAddr("fluid provider: no code at this address");
        assertEq(empty.code.length, 0);
        vm.expectRevert(FluidProvider.InvalidFToken.selector);
        new FluidProvider(empty);
        // a generic ERC4626 (MetaMorpho) has no getData(): reverts without data
        vm.expectRevert(bytes(""));
        new FluidProvider(STEAKHOUSE_VAULT);
    }

    /// The rate is the one the supply exchange price accrues at: Fluid's own view of that
    /// price, after a jump in time with no transaction in between, grows by rate * dt / year.
    function testRateIsTheAccrualOfTheSupplyExchangePrice() public {
        if (!forked) return;
        uint256 rate = provider.getDepositRate(vault);
        assertGt(rate, 0);
        (,,,,,,, uint256 before,) = fToken.getData();
        skip(30 days);
        (,,,,,,, uint256 later,) = fToken.getData();
        uint256 implied = ((later - before) * 1e27 * 365 days) / (before * 30 days);
        // the price accrues linearly from its last stored value, which compounds the
        // window by the time since that write: a relative error far below 0.1%
        assertApproxEqRel(rate, implied, 1e15, "ray rate equals the accrual of Fluid's supply exchange price");
    }

    function testActionsOnlyThroughTheVault() public {
        if (!forked) return;
        vm.expectRevert(FluidProvider.InvalidVaultContext.selector);
        provider.deposit(1e6, vault);
        vm.expectRevert(FluidProvider.InvalidVaultContext.selector);
        provider.withdraw(1e6, vault);
    }

    function testDepositAccruesAndFullExit() public {
        if (!forked) return;
        uint256 shares = _deposit(10_000e6);
        uint256 held = fToken.balanceOf(address(vault));
        assertGt(held, 0, "fToken shares held by the vault");
        assertEq(fToken.balanceOf(address(provider)), 0, "nothing held by the provider itself");
        assertEq(provider.getDepositBalance(address(vault), vault), fToken.previewRedeem(held));
        assertApproxEqAbs(provider.getDepositBalance(address(vault), vault), 10_001e6, FLUID_TOLERANCE);

        skip(30 days);
        vm.roll(block.number + 1);
        uint256 grown = provider.getDepositBalance(address(vault), vault);
        assertGt(grown, 10_001e6, "the exchange price accrues in the view, without a transaction");
        assertEq(grown, fToken.previewRedeem(held));
        assertTrue(vault.providersHealthy());

        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);
        assertGt(received, 10_000e6, "principal and interest back");
        assertEq(usdc.balanceOf(alice), received);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testRebalanceBetweenFluidAndMorpho() public {
        if (!forked) return;
        _deposit(10_000e6);
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory from = new IProvider[](1);
        IProvider[] memory to = new IProvider[](1);
        amounts[0] = 4_000e6;
        from[0] = provider;
        to[0] = STEAKHOUSE;
        vault.rebalance(amounts, from, to);
        assertApproxEqAbs(STEAKHOUSE.getDepositBalance(address(vault), vault), 4_000e6, 2);
        assertApproxEqAbs(provider.getDepositBalance(address(vault), vault), 6_001e6, FLUID_TOLERANCE);

        amounts[0] = 3_000e6;
        from[0] = STEAKHOUSE;
        to[0] = provider;
        vault.rebalance(amounts, from, to);
        assertApproxEqAbs(provider.getDepositBalance(address(vault), vault), 9_001e6, FLUID_TOLERANCE);
        assertApproxEqAbs(vault.totalAssets(), 10_001e6, FLUID_TOLERANCE, "rebalancing keeps NAV");
    }
}
