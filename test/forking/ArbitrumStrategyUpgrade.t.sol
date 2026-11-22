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
import {IPausableActions} from "../../contracts/interfaces/IPausableActions.sol";
import {FluidProvider} from "../../contracts/providers/FluidProvider.sol";
import {MorphoV2Provider} from "../../contracts/providers/MorphoV2Provider.sol";
import {IFluidFToken} from "../../contracts/interfaces/fluid/IFluid.sol";
import {IMorphoVaultV2} from "../../contracts/interfaces/morpho/IMorphoVaultV2.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";

/// @notice Rehearses the existing Arbitrum proxy and seven-source expansion on a pinned local fork.
/// @dev The HWM and venue caps here are simulation inputs, NOT governance attestations.
/// No private key or mainnet transaction is used: Forge writes only to its in-memory fork.
/// Run the fork EVM with Prague for current venue opcodes; the three required
/// ARBITRUM_*_CREATION_CODE inputs contain the reviewed Paris artifact bytecodes.
contract ArbitrumStrategyUpgradeForkTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant STRATEGY = 0xD211BfFAB29e60c17a2B406B3FAf3d0E29282B71;
    address internal constant AGENT = 0x10DaB1A9BB794A53849D295fF08768345888Ddd9;
    address internal constant LEGACY_IMPLEMENTATION = 0x84163d2d9CFfe0e53078C3Cd02ee3db1975117d5;
    address internal constant FUSDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address internal constant LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address internal constant GAUNTLET_V2 = 0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78;
    address internal constant ALLOCATOR_EXECUTOR = 0x9B77753b62d179e35C670E6179F577f4399D82FE;
    address internal constant EXISTING_EXECUTOR = 0x8d850d6807B115AC47F43bd04214A60d83fa47eD;
    bytes32 internal constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant STRATEGY_SLOT = 0x7e58afa6d55148d409feb524397452494284df87c6d0256f1c37551f5f960b00;
    bytes32 internal constant TARGET_RUNTIME = 0x6a9f9388ac5290c7a04b2415178eed2c197d1f11079913870b167765a229026b;
    bytes32 internal constant TARGET_CREATION = 0x0351f0dac96a68aa7f271dc7bcc25567f60acb302f231260b436a7f4a87ad747;
    bytes32 internal constant FLUID_CREATION = 0x30afe8b917dbf7b6169a8c3fe3a053bb5293e20dfb359f11b2c13a10c3884f36;
    bytes32 internal constant V2_CREATION = 0x239d13cc8bb0751f95880bfe827f000dfa22170b6a5229f2f811035551038963;
    bytes32 internal constant FLUID_RUNTIME = 0xb55df3954f38e547b6af0a24f5ce548d4587b32558e4478dbc509bb992f648bb;
    bytes32 internal constant V2_RUNTIME = 0xf103314d8d86b2a02a9ade7c2b6930c05c333d3d58d8e467563ad5ddbac86924;
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

    struct Before {
        bytes32[10] words;
        uint256 supply;
        uint256 assets;
        uint256 agentShares;
        uint256 seedShares;
        uint256 strategyCash;
        uint256 agentCash;
        address treasury;
        uint96 managementFee;
        uint96 performanceFee;
        bool depositPaused;
        bool withdrawPaused;
        uint256[5] balances;
        uint256[5] caps;
        address[5] sources;
        uint8[6] roles;
    }

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0);
        uint256 pin = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        require(pin != 0, "ARBITRUM_FORK_BLOCK must explicitly pin the rehearsal");
        vm.createSelectFork(url, pin);
        assertEq(block.chainid, 42161);
        // Arbitrum's EVM block.number is the L1 block, unlike the L2 RPC pin.
        emit log_named_uint("Pinned Arbitrum RPC block", pin);
        assertEq(address(uint160(uint256(vm.load(STRATEGY, IMPL_SLOT)))), LEGACY_IMPLEMENTATION);
        assertEq(LEGACY_IMPLEMENTATION.codehash, 0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3);
        assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + 10)), bytes32(0), "uninitialized legacy HWM");
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(STRATEGY, ADMIN_SLOT)))));
        governance = proxyAdmin.owner();
        timelock = Timelock(payable(strategy.getTimelock()));
        assertEq(address(timelock), 0x5383077e9BD3D476ab52d257f552Caa6C8Ebb948);
        original = strategy.getProviders();
        assertEq(original.length, 5, "attested legacy list");
        assertEq(address(original[0]), 0xA34574Dae6284EDc7348C36A80242b92CFBd13A5);
        assertEq(address(original[1]), 0x9eE0a4d3d9f4172FEB7E518EBbd73AF9a5E16664);
        assertEq(address(original[2]), 0xeB98d46937C537efF376361536D58d78c57c40d7);
        assertEq(address(original[3]), 0x6240402d3Cb33777D4E5E6B5791bC8518AEb8B99);
        assertEq(address(original[4]), 0x0D9FD60E25b0C3b2416D46F7dd311b0ED6743484);
        assertEq(address(strategy.getEntryProvider()), address(original[0]));
        assertEq(strategy.asset(), USDC);
        assertGt(strategy.totalSupply(), 0);
        testHighWaterMark = Math.mulDiv(strategy.totalAssets(), 1e18, strategy.totalSupply(), Math.Rounding.Ceil);
        alice = makeAddr("arbitrum strategy migration user");
    }

    function _create(bytes memory creation) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        require(deployed != address(0), "reviewed artifact deployment failed");
    }

    function _implementation() internal returns (Rebalancer implementation) {
        bytes memory creation = vm.envBytes("ARBITRUM_STRATEGY_CREATION_CODE");
        assertEq(keccak256(creation), TARGET_CREATION, "exact reviewed Paris creation code");
        implementation = Rebalancer(payable(_create(creation)));
        assertEq(address(implementation).codehash, TARGET_RUNTIME, "exact reviewed Paris runtime");
    }

    function _upgrade() internal {
        Rebalancer implementation = _implementation();
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (testHighWaterMark))
        );
        assertEq(address(uint160(uint256(vm.load(STRATEGY, IMPL_SLOT)))), address(implementation));
        assertEq(strategy.getHighWaterMark(), testHighWaterMark);
        assertTrue(strategy.providersHealthy());
    }

    function _actors() internal view returns (address[6] memory) {
        return [governance, timelock.owner(), AGENT, ALLOCATOR_EXECUTOR, EXISTING_EXECUTOR, alice];
    }

    function _roleMask(address actor) internal view returns (uint8) {
        return (strategy.hasRole(strategy.ADMIN_ROLE(), actor) ? 1 : 0)
            | (strategy.hasRole(strategy.EXECUTOR_ROLE(), actor) ? 2 : 0);
    }

    function _before() internal view returns (Before memory b) {
        for (uint256 i; i < 10; ++i) {
            b.words[i] = vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + i));
        }
        b.supply = strategy.totalSupply();
        b.assets = strategy.totalAssets();
        b.agentShares = strategy.balanceOf(AGENT);
        b.seedShares = strategy.balanceOf(STRATEGY);
        b.strategyCash = usdc.balanceOf(STRATEGY);
        b.agentCash = usdc.balanceOf(AGENT);
        b.treasury = strategy.getTreasury();
        b.managementFee = strategy.getManagementFee();
        b.performanceFee = strategy.getPerformanceFee();
        b.depositPaused = strategy.paused(IPausableActions.Actions.Deposit);
        b.withdrawPaused = strategy.paused(IPausableActions.Actions.Withdraw);
        address[6] memory actors = _actors();
        for (uint256 i; i < 5; ++i) {
            b.balances[i] = original[i].getDepositBalance(STRATEGY, strategy);
            b.caps[i] = strategy.getProviderCap(original[i]);
            b.sources[i] = original[i].getSource(USDC, STRATEGY, address(0));
        }
        for (uint256 i; i < actors.length; ++i) {
            b.roles[i] = _roleMask(actors[i]);
        }
    }

    function testAtomicUpgradePreservesLegacyStorageRolesAndPositions() public {
        Before memory b = _before();
        address admin = address(proxyAdmin);
        address lockOwner = timelock.owner();
        uint256 delay = timelock.delay();
        _upgrade();
        // lastAssets/lastTimestamp are the only legacy words intentionally reset.
        for (uint256 i; i < 6; ++i) {
            assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + i)), b.words[i]);
        }
        assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + 8)), b.words[8]);
        assertEq(vm.load(STRATEGY, bytes32(uint256(STRATEGY_SLOT) + 9)), b.words[9]);
        assertEq(address(uint160(uint256(vm.load(STRATEGY, ADMIN_SLOT)))), admin);
        assertEq(proxyAdmin.owner(), governance);
        assertEq(timelock.owner(), lockOwner);
        assertEq(timelock.delay(), delay);
        assertEq(strategy.totalSupply(), b.supply);
        assertEq(strategy.totalAssets(), b.assets);
        assertEq(strategy.getLastTotalAssets(), b.assets);
        assertEq(strategy.getLastTimestamp(), block.timestamp);
        assertEq(strategy.balanceOf(AGENT), b.agentShares);
        assertEq(strategy.balanceOf(STRATEGY), b.seedShares);
        assertEq(usdc.balanceOf(STRATEGY), b.strategyCash);
        assertEq(usdc.balanceOf(AGENT), b.agentCash);
        assertEq(strategy.getTreasury(), b.treasury);
        assertEq(strategy.getManagementFee(), b.managementFee);
        assertEq(strategy.getPerformanceFee(), b.performanceFee);
        assertEq(strategy.paused(IPausableActions.Actions.Deposit), b.depositPaused);
        assertEq(strategy.paused(IPausableActions.Actions.Withdraw), b.withdrawPaused);
        IProvider[] memory actual = strategy.getProviders();
        address[6] memory actors = _actors();
        for (uint256 i; i < 5; ++i) {
            assertEq(address(actual[i]), address(original[i]));
            assertEq(original[i].getDepositBalance(STRATEGY, strategy), b.balances[i]);
            assertEq(strategy.getProviderCap(original[i]), b.caps[i]);
            assertEq(strategy.getPinnedProviderSource(original[i]), b.sources[i]);
        }
        for (uint256 i; i < actors.length; ++i) {
            assertEq(_roleMask(actors[i]), b.roles[i]);
        }
        assertEq(address(strategy.getEntryProvider()), address(original[0]));
    }

    function testBareUpgradeAndInvalidInitializersFailClosed() public {
        Rebalancer implementation = _implementation();
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(STRATEGY), address(implementation), "");
        assertEq(strategy.getHighWaterMark(), 0);
        // The current legacy providers have no source pins after a bare upgrade.
        vm.expectRevert(IRebalancer.ProviderUnavailable.selector);
        strategy.convertToAssets(1e6);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(alice);
        strategy.initializeSecurityAccounting(testHighWaterMark);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (0))
        );
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (testHighWaterMark - 1))
        );
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (testHighWaterMark))
        );
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        vm.prank(governance);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STRATEGY),
            address(implementation),
            abi.encodeCall(Rebalancer.initializeSecurityAccounting, (testHighWaterMark))
        );
    }

    function _register() internal {
        bytes memory fluidCreation = vm.envBytes("ARBITRUM_FLUID_CREATION_CODE");
        bytes memory v2Creation = vm.envBytes("ARBITRUM_V2_CREATION_CODE");
        assertEq(keccak256(fluidCreation), FLUID_CREATION, "exact reviewed Fluid Paris creation code");
        assertEq(keccak256(v2Creation), V2_CREATION, "exact reviewed V2 Paris creation code");
        fluid = FluidProvider(_create(bytes.concat(fluidCreation, abi.encode(FUSDC))));
        v2 = MorphoV2Provider(_create(bytes.concat(v2Creation, abi.encode(GAUNTLET_V2))));
        assertEq(address(fluid).codehash, FLUID_RUNTIME, "Fluid immutable runtime");
        assertEq(address(v2).codehash, V2_RUNTIME, "V2 immutable runtime");
        IProvider[] memory expanded = new IProvider[](7);
        uint256[5] memory caps;
        for (uint256 i; i < 5; ++i) {
            expanded[i] = original[i];
            caps[i] = strategy.getProviderCap(original[i]);
        }
        expanded[5] = fluid;
        expanded[6] = v2;
        bytes memory providers = abi.encode(expanded);
        uint256 eta = block.timestamp + timelock.delay();
        assertEq(timelock.delay(), 24 hours, "actual stand governance delay");
        address owner = timelock.owner();
        vm.startPrank(owner);
        timelock.queue(STRATEGY, 0, "setProviders(address[])", providers, eta);
        timelock.queue(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, 3000), eta);
        timelock.queue(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(v2, 2000), eta);
        vm.expectRevert(Timelock.Timelock__StillLocked.selector);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", providers, eta);
        vm.warp(eta);
        timelock.execute(STRATEGY, 0, "setProviders(address[])", providers, eta);
        timelock.execute(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(fluid, 3000), eta);
        timelock.execute(STRATEGY, 0, "setProviderCap(address,uint256)", abi.encode(v2, 2000), eta);
        vm.stopPrank();
        IProvider[] memory actual = strategy.getProviders();
        assertEq(actual.length, 7);
        for (uint256 i; i < 5; ++i) {
            assertEq(address(actual[i]), address(original[i]));
            assertEq(strategy.getProviderCap(original[i]), caps[i]);
        }
        assertEq(address(actual[5]), address(fluid));
        assertEq(address(actual[6]), address(v2));
        assertEq(strategy.getProviderCap(fluid), 3000);
        assertEq(strategy.getProviderCap(v2), 2000);
        assertEq(address(strategy.getEntryProvider()), address(original[0]));
        assertEq(strategy.getPinnedProviderSource(fluid), FUSDC);
        assertEq(strategy.getPinnedProviderSource(v2), GAUNTLET_V2);
        for (uint256 i; i < actual.length; ++i) {
            address source = strategy.getPinnedProviderSource(actual[i]);
            assertTrue(source != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(source != strategy.getPinnedProviderSource(actual[j]), "unique source identities");
            }
        }
        assertEq(address(fluid.liquidity()), LIQUIDITY);
        assertEq(IFluidFToken(FUSDC).asset(), USDC);
        assertEq(IMorphoVaultV2(GAUNTLET_V2).asset(), USDC);
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

    function _roundTrip(IProvider venue) internal {
        uint256 agentShares = strategy.balanceOf(AGENT);
        uint256 seedShares = strategy.balanceOf(STRATEGY);
        uint256 baseline = strategy.totalAssets();
        uint256 userShares = _deposit(100e6);
        _move(original[0], venue, 10e6);
        assertApproxEqAbs(venue.getDepositBalance(STRATEGY, strategy), 10e6, ROUNDING, "new position NAV");
        assertGt(venue.getDepositRate(strategy), 0, "new venue APR readable");
        assertApproxEqAbs(strategy.totalAssets(), baseline + 100e6, ROUNDING, "seven-source NAV reconciles");
        _move(venue, original[0], type(uint256).max);
        assertLe(venue.getDepositBalance(STRATEGY, strategy), ROUNDING, "normal withdrawal exits new venue");
        vm.prank(alice);
        uint256 received = strategy.redeem(userShares, alice, alice);
        assertApproxEqAbs(received, 100e6, ROUNDING, "user receives principal");
        assertEq(usdc.balanceOf(alice), received);
        assertEq(strategy.balanceOf(alice), 0);
        assertEq(strategy.balanceOf(AGENT), agentShares);
        assertEq(strategy.balanceOf(STRATEGY), seedShares);
        assertApproxEqAbs(strategy.totalAssets(), baseline, ROUNDING, "existing holder NAV preserved");
    }

    function testFluidRegistrationAndNormalRoundTrip() public {
        _upgrade();
        _register();
        _roundTrip(fluid);
    }

    function testGauntletV2RegistrationAndNormalRoundTrip() public {
        _upgrade();
        _register();
        _roundTrip(v2);
    }

    function testNewVenueCapsRejectOversizedAllocationAtomically() public {
        _upgrade();
        _register();
        _deposit(1000e6);
        uint256 assets = strategy.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(fluid)));
        _move(original[0], fluid, 400e6);
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(v2)));
        _move(original[0], v2, 400e6);
        assertEq(strategy.totalAssets(), assets, "rejected rebalance is atomic");
        assertEq(fluid.getDepositBalance(STRATEGY, strategy), 0);
        assertEq(v2.getDepositBalance(STRATEGY, strategy), 0);
    }

    function testExistingSpokeAgentAllocateAndDeallocate() public {
        _upgrade();
        _register();
        ChainAgent agent = ChainAgent(AGENT);
        uint256 idle = agent.idle();
        uint256 value = strategy.convertToAssets(agent.strategyShares());
        vm.prank(governance);
        agent.deallocate(1e6);
        assertEq(agent.idle(), idle + 1e6, "existing spoke receives withdrawal");
        vm.prank(governance);
        agent.allocate(1e6);
        assertEq(agent.idle(), idle, "existing spoke redeposits only requested amount");
        assertApproxEqAbs(strategy.convertToAssets(agent.strategyShares()), value, ROUNDING);
        assertTrue(strategy.providersHealthy());
    }
}
