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
import {MorphoV2Provider} from "../../contracts/providers/MorphoV2Provider.sol";
import {IFluidFToken} from "../../contracts/interfaces/fluid/IFluid.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {EpochVault} from "../../contracts/tick/EpochVault.sol";
import {ForkPins} from "./ForkPins.sol";

/// @notice Replays the existing Base cross-chain Strategy, not a freshly initialized substitute.
/// @dev All deployments, impersonation and governance calls exist only on the local fork.
/// The ceiling PPS used here tests the migration; it is NOT a historical HWM attestation.
contract BaseStrategyExpansionForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant STRATEGY = 0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33;
    address internal constant AGENT = 0x3BAf244cAB9a35F75e5F606704Ad7A9D09C16B83;
    address internal constant EPOCH_VAULT = 0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6;
    address internal constant LEGACY_IMPLEMENTATION = 0xfcE142db5FD78F64c97b04d9a587E2C53341b910;
    address internal constant FUSDC = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GAUNTLET_V2 = 0x050cE30b927Da55177A4914EC73480238BAD56f0;
    bytes32 internal constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant STRATEGY_SLOT = 0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;
    uint256 internal constant ROUNDING = 100; // 0.0001 USDC, not a percentage tolerance.

    Rebalancer internal strategy = Rebalancer(payable(STRATEGY));
    IERC20 internal usdc = IERC20(USDC);
    address internal alice;
    address internal governance;
    ProxyAdmin internal proxyAdmin;
    Timelock internal timelock;
    FluidProvider internal fluid;
    MorphoV2Provider internal v2;
    IProvider[] internal original;
    uint256 internal testHighWaterMark;

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0);
        ForkPins.selectFork(vm, url, ForkPins.BASE_VAR, ForkPins.BASE);
        assertEq(block.chainid, 8453);
        assertEq(address(uint160(uint256(vm.load(STRATEGY, IMPL_SLOT)))), LEGACY_IMPLEMENTATION);
        assertEq(LEGACY_IMPLEMENTATION.codehash, 0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(STRATEGY, ADMIN_SLOT)))));
        governance = proxyAdmin.owner();
        timelock = Timelock(payable(strategy.getTimelock()));
        original = strategy.getProviders();
        assertEq(original.length, 5, "attested legacy list");
        assertEq(address(original[0]), 0xDDAA9700c0Da1020AE5dabC7AA0A0bb750DD317c);
        assertEq(address(original[1]), 0xa408A565a34B72FD6091f24b7ad4A15dCd29038a);
        assertEq(address(original[2]), 0x51B8BdCdA5E41893737C9C3A08f528C97fCc1b8b);
        assertEq(address(original[3]), 0x9c35b8a92Fc3a305712b9dD8a1C34310eA09C61c);
        assertEq(address(original[4]), 0xDDf2C1f8EAf567c084dEE07658Ed3906029395b1);
        testHighWaterMark = Math.mulDiv(strategy.totalAssets(), 1e18, strategy.totalSupply(), Math.Rounding.Ceil);
        alice = makeAddr("base expansion user");
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
        v2 = new MorphoV2Provider(GAUNTLET_V2);
        IProvider[] memory expanded = new IProvider[](7);
        for (uint256 i; i < original.length; ++i) {
            expanded[i] = original[i];
        }
        expanded[5] = fluid;
        expanded[6] = v2;
        bytes memory data = abi.encode(expanded);
        uint256 eta = block.timestamp + timelock.delay();
        assertEq(timelock.delay(), 24 hours, "stand governance delay");
        address owner = timelock.owner();
        uint256[] memory oldCaps = new uint256[](5);
        for (uint256 i; i < original.length; ++i) {
            oldCaps[i] = strategy.getProviderCap(original[i]);
        }
        vm.prank(owner);
        timelock.queue(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.prank(owner);
        timelock.queue(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, 3000), eta);
        vm.prank(owner);
        timelock.queue(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(v2, 2000), eta);
        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.warp(eta);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", data, eta);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, 3000), eta);
        vm.prank(owner);
        timelock.execute(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(v2, 2000), eta);
        assertTrue(strategy.hasRole(strategy.EXECUTOR_ROLE(), governance), "use existing executor");
        IProvider[] memory actual = strategy.getProviders();
        assertEq(actual.length, 7);
        for (uint256 i; i < original.length; ++i) {
            assertEq(address(actual[i]), address(original[i]));
            assertEq(strategy.getProviderCap(original[i]), oldCaps[i]);
        }
        assertEq(address(strategy.getEntryProvider()), address(original[0]));
        assertEq(strategy.getPinnedProviderSource(fluid), FUSDC);
        assertEq(strategy.getPinnedProviderSource(v2), GAUNTLET_V2);
        for (uint256 i; i < actual.length; ++i) {
            address source = strategy.getPinnedProviderSource(actual[i]);
            assertTrue(source != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(source != strategy.getPinnedProviderSource(actual[j]));
            }
        }
        assertEq(address(fluid.liquidity()), LIQUIDITY);
        assertEq(IFluidFToken(FUSDC).asset(), USDC);
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
        uint256[] memory balances = new uint256[](5);
        uint256[] memory caps = new uint256[](5);
        for (uint256 i; i < original.length; ++i) {
            balances[i] = original[i].getDepositBalance(STRATEGY, strategy);
            caps[i] = strategy.getProviderCap(original[i]);
        }
        _upgrade();
        // The lastAssets/lastTime words are deliberately reset by migration.
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
            assertEq(original[i].getDepositBalance(STRATEGY, strategy), balances[i]);
            assertEq(strategy.getProviderCap(original[i]), caps[i]);
        }
        assertTrue(strategy.hasRole(strategy.ADMIN_ROLE(), governance));
    }

    function _roundTrip(IProvider venue) internal {
        uint256 agentShares = strategy.balanceOf(AGENT);
        uint256 seedShares = strategy.balanceOf(STRATEGY);
        uint256 baseline = strategy.totalAssets();
        uint256 userShares = _deposit(100e6);
        _move(original[0], venue, 10e6);
        uint256 held = venue.getDepositBalance(STRATEGY, strategy);
        assertApproxEqAbs(held, 10e6, ROUNDING, "new position accurately valued");
        assertGt(venue.getDepositRate(strategy), 0, "new venue APR readable");
        assertApproxEqAbs(strategy.totalAssets(), baseline + 100e6, ROUNDING, "all seven-source NAV reconciles");
        _move(venue, original[0], type(uint256).max);
        assertLe(venue.getDepositBalance(STRATEGY, strategy), ROUNDING, "new venue exited without forced deallocation");
        vm.prank(alice);
        uint256 received = strategy.redeem(userShares, alice, alice);
        assertApproxEqAbs(received, 100e6, ROUNDING, "user gets principal back");
        assertEq(usdc.balanceOf(alice), received);
        assertEq(strategy.balanceOf(alice), 0);
        assertEq(strategy.balanceOf(AGENT), agentShares);
        assertEq(strategy.balanceOf(STRATEGY), seedShares);
        assertApproxEqAbs(strategy.totalAssets(), baseline, ROUNDING, "old holder NAV preserved");
    }

    function testSevenSourceRegistrationAndFluidRoundTrip() public {
        _upgrade();
        _register();
        _roundTrip(fluid);
    }

    function testSevenSourceRegistrationAndGauntletV2RoundTrip() public {
        _upgrade();
        _register();
        _roundTrip(v2);
    }

    function testNewVenueCapsRejectOversizedAllocation() public {
        _upgrade();
        _register();
        _deposit(1000e6);
        uint256 before = strategy.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(fluid)));
        _move(original[0], fluid, 400e6);
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(v2)));
        _move(original[0], v2, 400e6);
        assertEq(strategy.totalAssets(), before, "rejected rebalance is atomic");
        assertEq(fluid.getDepositBalance(STRATEGY, strategy), 0);
        assertEq(v2.getDepositBalance(STRATEGY, strategy), 0);
    }

    function testFluidBaseRateMatchesSupplyExchangePriceAccrual() public {
        fluid = new FluidProvider(FUSDC);
        uint256 rate = fluid.getDepositRate(strategy);
        assertGt(rate, 0);
        (,,,,,,, uint256 before,) = IFluidFToken(FUSDC).getData();
        skip(30 days);
        (,,,,,,, uint256 later,) = IFluidFToken(FUSDC).getData();
        uint256 implied = ((later - before) * 1e27 * 365 days) / (before * 30 days);
        assertApproxEqRel(rate, implied, 1e15, "Base Liquidity storage layout matches FluidProvider APR math");
    }

    function testExistingChainAgentAllocateDeallocateAndReturnFunds() public {
        _upgrade();
        _register();
        ChainAgent agent = ChainAgent(AGENT);
        EpochVault hub = EpochVault(EPOCH_VAULT);
        uint256 initialIdle = agent.idle();
        uint256 initialAgentValue = strategy.convertToAssets(agent.strategyShares());
        (uint256 initialCash,,,,,) = hub.accounting();
        vm.prank(governance);
        agent.deallocate(1e6);
        assertEq(agent.idle(), initialIdle + 1e6, "actual strategy exit credits agent");
        vm.prank(governance);
        agent.allocate(1e6);
        assertEq(agent.idle(), initialIdle, "actual strategy entry consumes only requested idle");
        assertApproxEqAbs(strategy.convertToAssets(agent.strategyShares()), initialAgentValue, ROUNDING);
        vm.prank(governance);
        agent.deallocate(1e6);
        vm.prank(governance);
        agent.returnToVault(1e6);
        assertEq(agent.idle(), initialIdle);
        (uint256 returnedCash,,,,,) = hub.accounting();
        assertEq(returnedCash, initialCash + 1e6, "existing hub accounts returned USDC");
        assertTrue(strategy.providersHealthy());
    }
}
