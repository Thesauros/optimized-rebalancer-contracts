// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {ProviderManager} from "../../contracts/utils/ProviderManager.sol";
import {VaultFactory} from "../../contracts/utils/VaultFactory.sol";
import {CompoundV3Provider} from "../../contracts/providers/CompoundV3Provider.sol";
import {Test} from "forge-std/Test.sol";

/**
 * The cross-chain strategy on Ethereum exactly as deploy/crosschain/01-deploy.ts
 * builds it from the `mainnet` registry entry: the Morpho providers the Ethereum
 * vault already runs, reused at their deployed addresses, plus a fresh
 * ProviderManager and CompoundV3Provider for Comet cUSDCv3, with the registry
 * caps. Needs ETHEREUM_RPC_URL; skipped without it.
 */
contract CrossChainStrategyEthereumForkTest is Test {
    uint256 internal constant ONE = 1e6;
    uint256 internal constant DEPOSIT = 10_000e6;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    // registry `mainnet.strategy.reusedProviders`, entry provider first
    IProvider internal constant STEAKHOUSE = IProvider(0x4C7e55689aCcC42562E113e04c3BDe1B2eb76622);
    IProvider internal constant GAUNTLET_PRIME = IProvider(0xBC64abbCa87289746f2B01C8ab02A78c9fC92B89);
    IProvider internal constant SMOKEHOUSE = IProvider(0x2fe36048F394A0732E8F28C43DbF351F0253C6E5);
    // the MetaMorpho V1.0 vaults behind them
    address internal constant STEAKHOUSE_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address internal constant GAUNTLET_PRIME_VAULT = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    address internal constant SMOKEHOUSE_VAULT = 0xBEeFFF209270748ddd194831b3fa287a5386f5bC;

    // registry `mainnet.strategy.capsBps`
    uint256 internal constant CAP_COMPOUND = 5_000;
    uint256 internal constant CAP_GAUNTLET_PRIME = 4_000;
    uint256 internal constant CAP_SMOKEHOUSE = 3_000;

    address internal agent = makeAddr("chainAgent");
    address internal executor = makeAddr("executor");
    address internal treasury = makeAddr("treasury");

    IERC20Metadata internal usdc = IERC20Metadata(USDC);
    CompoundV3Provider internal compound;
    Rebalancer internal strategy;
    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        // 01-deploy.ts: fresh ProviderManager + CompoundV3Provider, spliced in after the entry
        ProviderManager pm = new ProviderManager(address(this));
        pm.setYieldToken("Compound_V3_Provider", USDC, COMET);
        compound = new CompoundV3Provider(address(pm));
        IProvider[] memory providers = new IProvider[](4);
        providers[0] = STEAKHOUSE;
        providers[1] = IProvider(address(compound));
        providers[2] = GAUNTLET_PRIME;
        providers[3] = SMOKEHOUSE;

        // proxy created and initialized atomically by VaultFactory, seeded with 1 USDC
        Rebalancer implementation = new Rebalancer();
        VaultFactory factory = new VaultFactory();
        bytes memory init = abi.encodeWithSelector(
            Rebalancer.initialize.selector,
            address(this),
            address(this),
            USDC,
            "Thesauros Cross-Chain Strategy (Ethereum)",
            "tcsUSDC-eth",
            providers,
            treasury,
            uint96(0),
            uint96(0),
            ONE
        );
        deal(USDC, address(this), ONE);
        usdc.approve(address(factory), ONE);
        strategy = Rebalancer(payable(factory.deployAndInitialize(address(implementation), treasury, address(this), usdc, ONE, init)));

        // 02-configure.ts: caps and the executor
        strategy.setProviderCap(IProvider(address(compound)), CAP_COMPOUND);
        strategy.setProviderCap(GAUNTLET_PRIME, CAP_GAUNTLET_PRIME);
        strategy.setProviderCap(SMOKEHOUSE, CAP_SMOKEHOUSE);
        strategy.grantRole(strategy.EXECUTOR_ROLE(), executor);
    }

    function _deposit(uint256 amount) internal {
        deal(USDC, agent, amount);
        vm.startPrank(agent);
        usdc.approve(address(strategy), amount);
        strategy.deposit(amount, agent);
        vm.stopPrank();
    }

    function _move(IProvider from, IProvider to, uint256 amount) internal {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = amount;
        sources[0] = from;
        destinations[0] = to;
        vm.prank(executor);
        strategy.rebalance(amounts, sources, destinations);
    }

    function testReusedProvidersAreTheDeployedMorphoProviders() public view {
        if (!forked) return;
        address[3] memory providers = [address(STEAKHOUSE), address(GAUNTLET_PRIME), address(SMOKEHOUSE)];
        address[3] memory vaults = [STEAKHOUSE_VAULT, GAUNTLET_PRIME_VAULT, SMOKEHOUSE_VAULT];
        for (uint256 i; i < 3; i++) {
            assertGt(providers[i].code.length, 0, "deployed");
            assertEq(IProvider(providers[i]).getIdentifier(), "Morpho_Provider");
            assertEq(IProvider(providers[i]).getSource(USDC, address(0), address(0)), vaults[i], "provider wraps the registry vault");
            assertGt(IProvider(providers[i]).getDepositRate(strategy), 0, "rate readable");
        }
        assertEq(compound.getSource(USDC, address(0), address(0)), COMET, "Compound resolves cUSDCv3");
        assertGt(compound.getDepositRate(strategy), 0, "Comet rate readable");
    }

    function testWiringMatchesTheRegistry() public view {
        if (!forked) return;
        IProvider[] memory listed = strategy.getProviders();
        assertEq(listed.length, 4);
        assertEq(address(listed[0]), address(STEAKHOUSE));
        assertEq(address(listed[1]), address(compound));
        assertEq(address(listed[2]), address(GAUNTLET_PRIME));
        assertEq(address(listed[3]), address(SMOKEHOUSE));
        assertEq(address(strategy.getEntryProvider()), address(STEAKHOUSE), "entry provider");
        assertEq(strategy.getProviderCap(STEAKHOUSE), 0, "entry stays uncapped");
        assertEq(strategy.getProviderCap(IProvider(address(compound))), CAP_COMPOUND);
        assertEq(strategy.getProviderCap(GAUNTLET_PRIME), CAP_GAUNTLET_PRIME);
        assertEq(strategy.getProviderCap(SMOKEHOUSE), CAP_SMOKEHOUSE);
        assertEq(strategy.getPinnedProviderSource(STEAKHOUSE), STEAKHOUSE_VAULT, "source pinned");
        assertEq(strategy.getPinnedProviderSource(IProvider(address(compound))), COMET);
        assertTrue(strategy.providersHealthy(), "every provider view answers");
        assertApproxEqAbs(STEAKHOUSE.getDepositBalance(address(strategy), strategy), ONE, 1, "seed at the entry provider");
    }

    function testDepositSpreadWithinCapsAndFullExit() public {
        if (!forked) return;
        _deposit(DEPOSIT);
        assertApproxEqAbs(STEAKHOUSE.getDepositBalance(address(strategy), strategy), DEPOSIT + ONE, 2, "deposit lands at the entry");

        // spread as the executor would: 40% / 30% / 20%, each under its cap
        _move(STEAKHOUSE, IProvider(address(compound)), 4_000e6);
        _move(STEAKHOUSE, GAUNTLET_PRIME, 3_000e6);
        _move(STEAKHOUSE, SMOKEHOUSE, 2_000e6);
        assertApproxEqAbs(compound.getDepositBalance(address(strategy), strategy), 4_000e6, 2);
        assertApproxEqAbs(GAUNTLET_PRIME.getDepositBalance(address(strategy), strategy), 3_000e6, 2);
        assertApproxEqAbs(SMOKEHOUSE.getDepositBalance(address(strategy), strategy), 2_000e6, 2);
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT + ONE, 8, "rebalancing keeps NAV");

        // the agent deallocates everything: liquidity comes from all four providers
        skip(1 hours);
        vm.roll(block.number + 300);
        uint256 shares = strategy.balanceOf(agent);
        vm.prank(agent);
        uint256 assets = strategy.redeem(shares, agent, agent);
        assertGe(assets, DEPOSIT - 8, "principal back (providers round by a unit each)");
        assertEq(usdc.balanceOf(agent), assets);
        assertEq(strategy.balanceOf(agent), 0);
    }

    function testCapsRefuseConcentration() public {
        if (!forked) return;
        _deposit(DEPOSIT);
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = 6_000e6; // 60% of NAV into Compound, cap 50%
        sources[0] = STEAKHOUSE;
        destinations[0] = IProvider(address(compound));
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IRebalancer.ProviderCapExceeded.selector, address(compound)));
        strategy.rebalance(amounts, sources, destinations);
    }
}
