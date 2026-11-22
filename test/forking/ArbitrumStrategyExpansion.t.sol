// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {FluidProvider} from "../../contracts/providers/FluidProvider.sol";
import {IFluidFToken} from "../../contracts/interfaces/fluid/IFluid.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {ForkPins} from "./ForkPins.sol";

/**
 * @notice Replays the existing Arbitrum cross-chain Strategy, not a freshly initialized substitute.
 * @dev All deployments, impersonation and governance calls exist only on the local fork.
 *
 * The Arbitrum spoke still runs the implementation Base ran before its 2026-11-15 upgrade:
 * both are codehash 0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3, and
 * `getHighWaterMark()` reverts on Arbitrum while it answers on Base. Registering Fluid is
 * therefore not a two-call governance sequence; it needs the same atomic upgrade and security
 * accounting migration Base took, which is what this test rehearses.
 *
 * Only Fluid is added. A Gauntlet Morpho Vault V2 does exist on Arbitrum,
 * 0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78, interface-identical to Base's and under the same
 * curator, but it holds 191,941 USDC with its underlying markets near 91% utilisation, so the
 * spoke would dominate it. The expansion is to six providers, not seven.
 *
 * LIFETIME OF THIS TEST. `ForkPins.ARBITRUM` is 0, so this floats at head: the configured
 * Arbitrum RPC does not serve historical state, which is why the pin is absent. Unlike
 * `BaseStrategyExpansionForkTest`, pinned to block 55_863_000 and therefore permanently
 * reproducible, the assertions in `setUp` describe a spoke that has NOT been upgraded yet.
 * Once the real upgrade executes they will fail, and that failure is the signal to retire
 * this file rather than to relax it. Do not re-pin it to a post-upgrade block.
 *
 * The ceiling PPS used here tests the migration; it is NOT a historical HWM attestation.
 */
contract ArbitrumStrategyExpansionForkTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant STRATEGY = 0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71;
    address internal constant AGENT = 0x10DaB1A9BB794A53849D295fF08768345888Ddd9;
    address internal constant CURRENT_IMPLEMENTATION = 0x84163d2d9CFfe0e53078C3Cd02ee3db1975117d5;
    /// The bytecode Base ran before its upgrade. Shared, so the migration path is shared too.
    bytes32 internal constant LEGACY_CODEHASH = 0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3;
    address internal constant FUSDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    bytes32 internal constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant STRATEGY_SLOT = 0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;
    uint256 internal constant ROUNDING = 100; // 0.0001 USDC, not a percentage tolerance.
    uint256 internal constant FLUID_CAP = 3000;

    Rebalancer internal strategy = Rebalancer(payable(STRATEGY));
    IERC20 internal usdc = IERC20(USDC);
    address internal alice;
    address internal governance;
    ProxyAdmin internal proxyAdmin;
    Timelock internal timelock;
    FluidProvider internal fluid;
    IProvider[] internal original;
    uint256 internal testHighWaterMark;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0);
        ForkPins.selectFork(vm, url, ForkPins.ARBITRUM_VAR, ForkPins.ARBITRUM);
        assertEq(block.chainid, 42161);
        assertEq(address(uint160(uint256(vm.load(STRATEGY, IMPL_SLOT)))), CURRENT_IMPLEMENTATION);
        assertEq(CURRENT_IMPLEMENTATION.codehash, LEGACY_CODEHASH, "same bytecode Base ran pre-upgrade");
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(STRATEGY, ADMIN_SLOT)))));
        governance = proxyAdmin.owner();
        timelock = Timelock(payable(strategy.getTimelock()));
        original = strategy.getProviders();
        assertEq(original.length, 5, "attested legacy list");
        assertEq(address(original[0]), 0xA34574Dae6284EDc7348C36A80242b92CFBd13A5, "AaveV3 entry");
        assertEq(address(original[1]), 0x9eE0a4d3d9f4172FEB7E518EBbd73AF9a5E16664, "CompoundV3");
        assertEq(address(original[2]), 0xeB98d46937C537efF376361536D58d78c57c40d7, "GauntletCoreMorpho");
        assertEq(address(original[3]), 0x6240402d3Cb33777D4E5E6B5791bC8518AEb8B99, "SteakhouseHighYield");
        assertEq(address(original[4]), 0x0D9FD60E25b0C3b2416D46F7dd311b0ED6743484, "SteakhousePrime");
        vm.expectRevert();
        strategy.getHighWaterMark();
        testHighWaterMark = Math.mulDiv(strategy.totalAssets(), 1e18, strategy.totalSupply(), Math.Rounding.Ceil);
        alice = makeAddr("arbitrum expansion user");
    }

    function _upgrade() internal {
        Rebalancer implementation = new Rebalancer();
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (testHighWaterMark))
        );
        assertEq(strategy.getHighWaterMark(), testHighWaterMark);
        assertTrue(strategy.providersHealthy());
    }

    function _register() internal {
        fluid = new FluidProvider(FUSDC);
        IProvider[] memory expanded = new IProvider[](original.length + 1);
        for (uint256 i; i < original.length; ++i) {
            expanded[i] = original[i];
        }
        expanded[original.length] = fluid;
        bytes memory data = abi.encode(expanded);
        assertEq(timelock.delay(), 24 hours, "stand governance delay");
        address owner = timelock.owner();
        uint256 eta = block.timestamp + timelock.delay();
        uint256[] memory oldCaps = new uint256[](original.length);
        for (uint256 i; i < original.length; ++i) {
            oldCaps[i] = strategy.getProviderCap(original[i]);
        }
        vm.prank(owner);
        timelock.queue(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.prank(owner);
        timelock.queue(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, FLUID_CAP), eta);
        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.warp(eta);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, FLUID_CAP), eta);
        assertTrue(strategy.hasRole(strategy.EXECUTOR_ROLE(), governance), "use existing executor");
        IProvider[] memory actual = strategy.getProviders();
        assertEq(actual.length, original.length + 1);
        for (uint256 i; i < original.length; ++i) {
            assertEq(address(actual[i]), address(original[i]), "legacy order and membership preserved");
            assertEq(strategy.getProviderCap(original[i]), oldCaps[i], "legacy caps untouched");
        }
        assertEq(address(strategy.getEntryProvider()), address(original[0]), "entry provider unchanged");
        assertEq(strategy.getProviderCap(fluid), FLUID_CAP);
        assertEq(strategy.getPinnedProviderSource(fluid), FUSDC);
        for (uint256 i; i < actual.length; ++i) {
            address source = strategy.getPinnedProviderSource(actual[i]);
            assertTrue(source != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(source != strategy.getPinnedProviderSource(actual[j]), "distinct sources");
            }
        }
        assertEq(address(fluid.liquidity()), LIQUIDITY);
        assertEq(IFluidFToken(FUSDC).asset(), USDC, "fUSDC is over this spoke's USDC");
        assertTrue(strategy.providersHealthy());
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(USDC, alice, amount);
        vm.startPrank(alice);
        usdc.approve(STRATEGY, amount);
        shares = strategy.deposit(amount, alice);
        vm.stopPrank();
    }

    function _move(IProvider from, IProvider to, uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = amount;
        sources[0] = from;
        destinations[0] = to;
        vm.prank(governance);
        strategy.rebalance(amounts, sources, destinations);
    }

    function testAtomicUpgradePreservesLegacyStorageAndPositions() public {
        // Slots 0..9 are the deployed ERC7201 prefix (including the caps mapping).
        bytes32[] memory words = new bytes32[](10);
        for (uint256 i; i < words.length; ++i) {
            words[i] = vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + i));
        }
        uint256 supply = strategy.totalSupply();
        uint256 assets = strategy.totalAssets();
        uint256 agentShares = strategy.balanceOf(AGENT);
        uint256 seedShares = strategy.balanceOf(STRATEGY);
        uint256[] memory balances = new uint256[](original.length);
        uint256[] memory caps = new uint256[](original.length);
        for (uint256 i; i < original.length; ++i) {
            balances[i] = original[i].getDepositBalance(STRATEGY, strategy);
            caps[i] = strategy.getProviderCap(original[i]);
        }
        _upgrade();
        // The lastAssets/lastTime words are deliberately reset by the migration.
        for (uint256 i; i < 6; ++i) {
            assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + i)), words[i]);
        }
        assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + 8)), words[8]);
        assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + 9)), words[9]);
        assertEq(strategy.totalSupply(), supply);
        assertEq(strategy.totalAssets(), assets);
        assertEq(strategy.getLastTotalAssets(), assets);
        assertEq(strategy.getLastTimestamp(), block.timestamp);
        assertEq(strategy.balanceOf(AGENT), agentShares);
        assertEq(strategy.balanceOf(STRATEGY), seedShares);
        for (uint256 i; i < original.length; ++i) {
            assertEq(original[i].getDepositBalance(STRATEGY, strategy), balances[i], "position preserved");
            assertEq(strategy.getProviderCap(original[i]), caps[i], "cap preserved");
        }
        assertTrue(strategy.hasRole(strategy.ADMIN_ROLE(), governance));
    }

    function testSixSourceRegistrationAndFluidRoundTrip() public {
        _upgrade();
        _register();
        uint256 agentShares = strategy.balanceOf(AGENT);
        uint256 seedShares = strategy.balanceOf(STRATEGY);
        uint256 baseline = strategy.totalAssets();
        uint256 userShares = _deposit(100e6);
        _move(original[0], fluid, 10e6);
        assertApproxEqAbs(fluid.getDepositBalance(STRATEGY, strategy), 10e6, ROUNDING, "new position accurately valued");
        assertGt(fluid.getDepositRate(strategy), 0, "new venue APR readable");
        assertApproxEqAbs(strategy.totalAssets(), baseline + 100e6, ROUNDING, "all six-source NAV reconciles");
        _move(fluid, original[0], type(uint256).max);
        assertLe(fluid.getDepositBalance(STRATEGY, strategy), ROUNDING, "new venue exited without forced deallocation");
        vm.prank(alice);
        uint256 received = strategy.redeem(userShares, alice, alice);
        assertApproxEqAbs(received, 100e6, ROUNDING, "user gets principal back");
        assertEq(usdc.balanceOf(alice), received);
        assertEq(strategy.balanceOf(alice), 0);
        assertEq(strategy.balanceOf(AGENT), agentShares);
        assertEq(strategy.balanceOf(STRATEGY), seedShares);
        assertApproxEqAbs(strategy.totalAssets(), baseline, ROUNDING, "old holder NAV preserved");
    }

    function testNewVenueCapRejectsOversizedAllocation() public {
        _upgrade();
        _register();
        _deposit(1000e6);
        uint256 before = strategy.totalAssets();
        // 400 of a ~1003 USDC NAV is about 40%, over the 30% Fluid cap.
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(fluid)));
        _move(original[0], fluid, 400e6);
        assertEq(strategy.totalAssets(), before, "rejected rebalance is atomic");
        assertEq(fluid.getDepositBalance(STRATEGY, strategy), 0);
    }

    function testFluidArbitrumRateMatchesSupplyExchangePriceAccrual() public {
        fluid = new FluidProvider(FUSDC);
        uint256 rate = fluid.getDepositRate(strategy);
        assertGt(rate, 0);
        (,,,,,,, uint256 before,) = IFluidFToken(FUSDC).getData();
        skip(30 days);
        (,,,,,,, uint256 later,) = IFluidFToken(FUSDC).getData();
        uint256 implied = ((later - before) * 1e27 * 365 days) / (before * 30 days);
        assertApproxEqRel(rate, implied, 1e15, "Arbitrum Liquidity storage layout matches FluidProvider APR math");
    }

    /// The spoke agent still allocates and deallocates against the expanded strategy.
    /// `returnToVault` is not exercised here: it is a cross-chain send to the hub on Base
    /// and belongs to the Base-side replay, not to a single-chain Arbitrum fork.
    function testChainAgentAllocateAndDeallocateAfterExpansion() public {
        _upgrade();
        _register();
        ChainAgent agent = ChainAgent(AGENT);
        uint256 initialIdle = agent.idle();
        uint256 initialAgentValue = strategy.convertToAssets(agent.strategyShares());
        vm.prank(governance);
        agent.deallocate(1e6);
        assertEq(agent.idle(), initialIdle + 1e6, "actual strategy exit credits agent");
        vm.prank(governance);
        agent.allocate(1e6);
        assertEq(agent.idle(), initialIdle, "actual strategy entry consumes only requested idle");
        assertApproxEqAbs(strategy.convertToAssets(agent.strategyShares()), initialAgentValue, ROUNDING);
        assertTrue(strategy.providersHealthy());
    }
}
