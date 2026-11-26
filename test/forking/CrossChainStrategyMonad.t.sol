// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {VaultFactory} from "../../contracts/utils/VaultFactory.sol";
import {Test} from "forge-std/Test.sol";
import {ForkPins} from "./ForkPins.sol";

/**
 * @notice The cross-chain strategy on Monad exactly as deploy/crosschain/01-deploy.ts builds it
 *         from the `monad` registry entry: one reused provider, no fresh ones.
 * @dev Monad has a single venue this registry can name. `chainConfigs[143]` lists empty
 *      cometPairs and morphoVaults, Fluid publishes no Monad deployment, and Morpho Blue has no
 *      code there, so AaveV3 is the whole strategy and therefore its entry provider. With no
 *      `comet` there is no ProviderManager either: phase 1 deploys one only when a Comet is
 *      configured.
 *
 *      The point of this file is `testReuseLeavesTheStandaloneVaultPositionUntouched`. The
 *      registry reuses the standalone Monad vault's own AaveV3Provider at its deployed address,
 *      which is safe only because the provider is delegatecalled and holds no vault binding: it
 *      has one immutable, the PoolAddressesProvider, and every method takes the vault as an
 *      argument. Two vaults sharing one provider address must therefore hold two independent
 *      Aave positions, and this test proves it against live Monad state rather than asserting it
 *      from the source.
 *
 *      RUNNING THIS FILE. Forge 1.10.0 refuses a cheatcode-created Monad fork while its EVM is
 *      instantiated for Ethereum:
 *
 *        vm.createSelectFork: cannot create a `monad` fork with an EVM instantiated for `ethereum`
 *
 *      The EVM has to be selected for the chain up front, so this suite needs both `--rpc-url`
 *      and `--fork-block-number` on the command line, plus MONAD_RPC_URL so setUp does not skip:
 *
 *        MONAD_RPC_URL=https://rpc.monad.xyz \
 *          forge test --rpc-url https://rpc.monad.xyz --fork-block-number 124400000 \
 *          --match-contract CrossChainStrategyMonadForkTest
 *
 *      A plain `forge test --match-path 'test/forking/*'` therefore reports this file as
 *      SKIPPED, not passed and not failed. That is deliberate: `vm.skip` keeps the absence
 *      visible, where the early-return idiom used elsewhere in this directory would report a
 *      vacuous PASS that looks identical to a real one.
 *
 *      Pass MONAD_RPC_URL inline as shown, not exported into .env. Setting it globally makes
 *      the aggregate forking run fail in setUp with the EVM mismatch above, because that run
 *      does not carry --rpc-url. Failing loudly there is better than skipping silently, but it
 *      is not something to leave in a shared environment file.
 */
contract CrossChainStrategyMonadForkTest is Test {
    uint256 internal constant ONE = 1e6;
    uint256 internal constant DEPOSIT = 10_000e6;

    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant AAVE_POOL_ADDRESSES_PROVIDER = 0x34793Fb9935F7bB5E5aE920fb963F39063E7A615;
    address internal constant AAVE_POOL = 0x69a5F9AD4f96ebf0a0C792dD42a01cC5C0102fef;
    address internal constant AAVE_USDC_ATOKEN = 0x35a73BAcb179d3740395A3ceCc87FF2e581d6042;
    /// The standalone Monad vault, which already runs the provider this strategy reuses.
    address internal constant STANDALONE_VAULT = 0x40F1fBf6a92155a6D321c09936234BFEb9Ec4760;
    /// registry `monad.strategy.reusedProviders`, the only entry and so the entry provider
    IProvider internal constant AAVE = IProvider(0xAeEcf7F780e88B155df330434Ef29b2B077024e0);

    address internal agent = makeAddr("chainAgent");
    address internal executor = makeAddr("executor");
    address internal treasury = makeAddr("treasury");

    IERC20Metadata internal usdc = IERC20Metadata(USDC);
    Rebalancer internal strategy;

    function setUp() public {
        // Unset means skipped, not passed. See the NatSpec above for the full invocation, which
        // also needs --rpc-url and --fork-block-number because forge will not build a Monad fork
        // inside an Ethereum EVM.
        string memory url = vm.envOr("MONAD_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0);
        ForkPins.selectFork(vm, url, ForkPins.MONAD_VAR, ForkPins.MONAD);
        assertEq(block.chainid, 143);

        // 01-deploy.ts spoke path with no comet, no fluidFToken and no morphoV2Vault:
        // no ProviderManager, no fresh provider, just the reused one.
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = AAVE;

        Rebalancer implementation = new Rebalancer();
        VaultFactory factory = new VaultFactory();
        bytes memory init = abi.encodeWithSelector(
            Rebalancer.initialize.selector,
            address(this),
            address(this),
            USDC,
            "Thesauros Cross-Chain Strategy (Monad)",
            "tcsUSDC-mon",
            providers,
            treasury,
            uint96(0),
            uint96(0),
            ONE
        );
        deal(USDC, address(this), ONE);
        usdc.approve(address(factory), ONE);
        strategy = Rebalancer(payable(factory.deployAndInitialize(address(implementation), treasury, address(this), usdc, ONE, init)));

        // 02-configure.ts: the entry provider stays uncapped, so the only cap to set is 0.
        strategy.setProviderCap(AAVE, 0);
        strategy.grantRole(strategy.EXECUTOR_ROLE(), executor);
    }

    function testReusedProviderIsTheDeployedAaveProvider() public view {
        assertGt(address(AAVE).code.length, 0, "deployed");
        assertEq(AAVE.getIdentifier(), "Aave_V3_Provider");
        // getSource ignores its arguments and returns the Pool, so the pin recorded at
        // registration cannot drift the way an argument-dependent source could.
        assertEq(AAVE.getSource(USDC, address(0), address(0)), AAVE_POOL, "resolves the Aave Pool");
        assertEq(AAVE.getSource(USDC, address(strategy), address(strategy)), AAVE_POOL, "argument independent");
        assertGt(AAVE.getDepositRate(strategy), 0, "rate readable");
        // Monad names its Aave USDC receipt token aMonUSDC, not aUSDC as on the other chains.
        assertEq(IERC20Metadata(AAVE_USDC_ATOKEN).symbol(), "aMonUSDC", "the reserve is the USDC one");
        assertEq(IERC20Metadata(AAVE_USDC_ATOKEN).decimals(), 6, "and it is 6-decimal like the asset");
    }

    function testWiringMatchesTheRegistry() public view {
        IProvider[] memory listed = strategy.getProviders();
        assertEq(listed.length, 1, "Aave is the whole strategy on Monad");
        assertEq(address(listed[0]), address(AAVE));
        assertEq(address(strategy.getEntryProvider()), address(AAVE), "and therefore the entry provider");
        assertEq(strategy.getProviderCap(AAVE), 0, "the entry provider stays uncapped");
        assertEq(strategy.getPinnedProviderSource(AAVE), AAVE_POOL, "source pinned to the Pool");
        assertTrue(strategy.providersHealthy(), "every provider view answers");
        assertEq(strategy.asset(), USDC);
        assertEq(strategy.name(), "Thesauros Cross-Chain Strategy (Monad)");
        assertEq(strategy.symbol(), "tcsUSDC-mon");
        assertApproxEqAbs(AAVE.getDepositBalance(address(strategy), strategy), ONE, 1, "seed at the entry provider");
    }

    function testDepositAccruesAndFullExit() public {
        address alice = makeAddr("monad depositor");
        deal(USDC, alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(strategy), DEPOSIT);
        uint256 shares = strategy.deposit(DEPOSIT, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        assertApproxEqAbs(AAVE.getDepositBalance(address(strategy), strategy), DEPOSIT + ONE, 2, "deposit lands at the entry");
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT + ONE, 2);

        skip(30 days);
        vm.roll(block.number + 1);
        assertGt(strategy.totalAssets(), DEPOSIT + ONE, "Aave interest accrues in the view");

        vm.prank(alice);
        uint256 received = strategy.redeem(shares, alice, alice);
        assertGe(received, DEPOSIT, "principal back");
        assertEq(usdc.balanceOf(alice), received);
        assertEq(strategy.balanceOf(alice), 0);
    }

    /// The safety property that makes reuse acceptable: the cross-chain Strategy and the
    /// standalone vault share one provider address but hold separate Aave positions, because
    /// the provider is delegatecalled and mints aTokens to whichever vault it acts for.
    function testReuseLeavesTheStandaloneVaultPositionUntouched() public {
        uint256 standaloneBefore = AAVE.getDepositBalance(STANDALONE_VAULT, IRebalancer(STANDALONE_VAULT));
        uint256 standaloneAssetsBefore = IRebalancer(STANDALONE_VAULT).totalAssets();
        uint256 aTokenBefore = IERC20Metadata(AAVE_USDC_ATOKEN).balanceOf(STANDALONE_VAULT);
        assertGt(standaloneBefore, 0, "the standalone vault really does hold a position here");

        address alice = makeAddr("monad depositor");
        deal(USDC, alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(strategy), DEPOSIT);
        uint256 shares = strategy.deposit(DEPOSIT, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        assertApproxEqAbs(AAVE.getDepositBalance(address(strategy), strategy), DEPOSIT + ONE, 2, "the spoke has its own position");

        assertEq(AAVE.getDepositBalance(STANDALONE_VAULT, IRebalancer(STANDALONE_VAULT)), standaloneBefore, "standalone position unchanged");
        assertEq(IERC20Metadata(AAVE_USDC_ATOKEN).balanceOf(STANDALONE_VAULT), aTokenBefore, "standalone aTokens unchanged");
        assertEq(IRebalancer(STANDALONE_VAULT).totalAssets(), standaloneAssetsBefore, "standalone NAV unchanged");

        // and exiting the spoke does not touch it either
        vm.prank(alice);
        strategy.redeem(shares, alice, alice);
        assertEq(AAVE.getDepositBalance(STANDALONE_VAULT, IRebalancer(STANDALONE_VAULT)), standaloneBefore, "still unchanged after exit");
        assertEq(IERC20Metadata(AAVE_USDC_ATOKEN).balanceOf(STANDALONE_VAULT), aTokenBefore, "still unchanged after exit");
    }
}
