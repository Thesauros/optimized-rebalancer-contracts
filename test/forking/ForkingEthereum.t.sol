// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Timelock} from "../../contracts/access/Timelock.sol";
import {ProviderManager} from "../../contracts/utils/ProviderManager.sol";
import {VaultFactory} from "../../contracts/utils/VaultFactory.sol";
import {AaveV3Provider} from "../../contracts/providers/AaveV3Provider.sol";
import {CompoundV3Provider} from "../../contracts/providers/CompoundV3Provider.sol";
import {MorphoProvider} from "../../contracts/providers/MorphoProvider.sol";
import {CometInterface} from "../../contracts/interfaces/compoundV3/CometInterface.sol";
import {Test} from "forge-std/Test.sol";

/**
 * Ethereum mainnet fork coverage for the vault stack deployed by
 * deploy/deploy-usdc-vault.ts, including the atomic VaultFactory path that
 * replaces the three-transaction anti-sniping pipeline.
 */
contract ForkingEthereum is Test {
    uint256 public constant ONE = 1e6;
    uint256 public constant THOUSAND = 1000e6;

    address public constant USDC_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant COMET_USDC_ADDRESS =
        0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    address public constant AAVE_V3_POOL_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    address public constant MORPHO_STEAKHOUSE_VAULT_ADDRESS =
        0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address public constant MORPHO_GAUNTLET_PRIME_VAULT_ADDRESS =
        0xdd0f28e19C1780eb6396170735D45153D261490d;
    address public constant MORPHO_SMOKEHOUSE_VAULT_ADDRESS =
        0xBEeFFF209270748ddd194831b3fa287a5386f5bC;

    // protocol treasury (Gnosis Safe 1.4.1, 2/2) — vault admin and proxy admin owner
    address public constant TREASURY =
        0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1;
    // deployer EOA — owner of the Timelock and of the ProviderManager
    address public constant DEPLOYER =
        0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D;

    string public constant VAULT_NAME = "Thesauros USDC Vault";
    string public constant VAULT_SYMBOL = "tUSDC";
    uint256 public constant TIMELOCK_DELAY = 3600;

    address public alice = makeAddr("alice");
    address public keeper = makeAddr("keeper");

    event VaultDeployed(
        address indexed vault,
        address indexed implementation,
        address indexed admin
    );

    IERC20Metadata public usdc;
    ProviderManager public providerManager;
    CompoundV3Provider public compoundV3Provider;
    AaveV3Provider public aaveV3Provider;
    MorphoProvider public steakhouseProvider;
    MorphoProvider public gauntletPrimeProvider;
    MorphoProvider public smokehouseProvider;
    Timelock public timelock;
    Rebalancer public implementation;
    VaultFactory public factory;

    IProvider[] public providers;
    uint256 public minAssets = ONE;

    function setUp() public virtual {
        string memory ETHEREUM_RPC_URL = vm.envString("ETHEREUM_RPC_URL");
        vm.createSelectFork(ETHEREUM_RPC_URL);

        usdc = IERC20Metadata(USDC_ADDRESS);
        vm.label(address(usdc), "USDC");
        vm.label(TREASURY, "treasury");
        vm.label(DEPLOYER, "deployer");

        // mirrors deploy/deploy-usdc-vault.ts
        providerManager = new ProviderManager(address(this));
        providerManager.setYieldToken(
            "Compound_V3_Provider",
            USDC_ADDRESS,
            COMET_USDC_ADDRESS
        );

        compoundV3Provider = new CompoundV3Provider(address(providerManager));
        aaveV3Provider = new AaveV3Provider(AAVE_V3_POOL_ADDRESSES_PROVIDER);
        steakhouseProvider = new MorphoProvider(MORPHO_STEAKHOUSE_VAULT_ADDRESS);
        gauntletPrimeProvider = new MorphoProvider(
            MORPHO_GAUNTLET_PRIME_VAULT_ADDRESS
        );
        smokehouseProvider = new MorphoProvider(MORPHO_SMOKEHOUSE_VAULT_ADDRESS);

        // entry provider first, exactly as the deploy script orders them
        providers.push(IProvider(address(compoundV3Provider)));
        providers.push(IProvider(address(aaveV3Provider)));
        providers.push(IProvider(address(steakhouseProvider)));
        providers.push(IProvider(address(gauntletPrimeProvider)));
        providers.push(IProvider(address(smokehouseProvider)));

        timelock = new Timelock(DEPLOYER, TIMELOCK_DELAY);
        implementation = new Rebalancer();
        factory = new VaultFactory();
    }

    function _initCalldata() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                Rebalancer.initialize.selector,
                TREASURY,
                address(timelock),
                USDC_ADDRESS,
                VAULT_NAME,
                VAULT_SYMBOL,
                providers,
                TREASURY,
                uint96(0),
                uint96(0),
                minAssets
            );
    }

    /// @dev Deploys the proxy and initializes it in one transaction, as in production.
    function _deployVaultAtomically() internal returns (Rebalancer vault) {
        deal(address(usdc), address(this), minAssets);
        usdc.approve(address(factory), minAssets);

        address proxy = factory.deployAndInitialize(
            address(implementation),
            TREASURY,
            address(this),
            usdc,
            minAssets,
            _initCalldata()
        );
        vault = Rebalancer(payable(proxy));
    }

    // =========================================
    // atomic deploy + initialize
    // =========================================

    function testAtomicDeployAndInitialize() public {
        deal(address(usdc), address(this), minAssets);
        usdc.approve(address(factory), minAssets);

        // topic 1 is the proxy address, which is unknown before the call
        vm.expectEmit(false, true, true, true);
        emit VaultDeployed(address(0), address(implementation), TREASURY);

        Rebalancer vault = Rebalancer(
            payable(
                factory.deployAndInitialize(
                    address(implementation),
                    TREASURY,
                    address(this),
                    usdc,
                    minAssets,
                    _initCalldata()
                )
            )
        );

        // vault parameters match the chain config
        assertEq(vault.name(), VAULT_NAME);
        assertEq(vault.symbol(), VAULT_SYMBOL);
        assertEq(vault.asset(), USDC_ADDRESS);
        assertEq(vault.decimals(), 6);
        assertEq(address(vault.getTimelock()), address(timelock));
        assertEq(vault.getTreasury(), TREASURY);
        assertEq(vault.getManagementFee(), 0);
        assertEq(vault.getPerformanceFee(), 0);
        assertEq(vault.getMinAssets(), minAssets);

        // admin is the treasury Safe, not the deployer and not the test account
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), TREASURY));
        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), DEPLOYER));
        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), address(this)));

        // inflation-attack seed: shares minted to the vault itself
        assertEq(vault.totalSupply(), minAssets);
        assertEq(vault.balanceOf(address(vault)), minAssets);
        // provider balances round against the ERC-4626 supply, so the seed can
        // read back one unit low
        assertApproxEqAbs(vault.totalAssets(), minAssets, 1);
        assertEq(vault.getLastTotalAssets(), minAssets);

        // provider wiring
        IProvider[] memory listed = vault.getProviders();
        assertEq(listed.length, providers.length);
        for (uint256 i; i < listed.length; i++) {
            assertEq(address(listed[i]), address(providers[i]));
        }
        assertEq(
            address(vault.getEntryProvider()),
            address(compoundV3Provider)
        );

        // the seed reached the entry provider
        assertGe(
            CometInterface(COMET_USDC_ADDRESS).balanceOf(address(vault)),
            minAssets - 1
        );

        // proxy admin is a ProxyAdmin owned by the treasury
        address proxyAdmin = vm.computeCreateAddress(address(vault), 1);
        assertEq(ProxyAdmin(proxyAdmin).owner(), TREASURY);

        // nothing is stranded in the factory and no allowance survives
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(usdc.allowance(address(factory), address(vault)), 0);
        assertEq(usdc.balanceOf(address(this)), 0);
    }

    function testFactoryRejectsForeignSeedOwner() public {
        // we approved the factory for our own seed; somebody else must not be
        // able to spend that approval by passing us as seedOwner_
        deal(address(usdc), address(this), minAssets);
        usdc.approve(address(factory), minAssets);

        vm.prank(alice);
        vm.expectRevert(VaultFactory.NotSeedOwner.selector);
        factory.deployAndInitialize(
            address(implementation),
            TREASURY,
            address(this),
            usdc,
            minAssets,
            _initCalldata()
        );

        assertEq(usdc.balanceOf(address(this)), minAssets);
    }

    function testFactoryBubblesUpInitializeRevert() public {
        deal(address(usdc), address(this), minAssets);
        usdc.approve(address(factory), minAssets);

        // minAssets_ == 0 makes initialize revert InvalidInput
        bytes memory badInit = abi.encodeWithSelector(
            Rebalancer.initialize.selector,
            TREASURY,
            address(timelock),
            USDC_ADDRESS,
            VAULT_NAME,
            VAULT_SYMBOL,
            providers,
            TREASURY,
            uint96(0),
            uint96(0),
            uint256(0)
        );

        vm.expectRevert(IRebalancer.InvalidInput.selector);
        factory.deployAndInitialize(
            address(implementation),
            TREASURY,
            address(this),
            usdc,
            minAssets,
            badInit
        );

        // the whole transaction reverted: the seed is untouched
        assertEq(usdc.balanceOf(address(this)), minAssets);
    }

    function testFactoryReturnsLeftoverSeed() public {
        uint256 oversizedSeed = 5 * ONE;
        deal(address(usdc), address(this), oversizedSeed);
        usdc.approve(address(factory), oversizedSeed);

        Rebalancer vault = Rebalancer(
            payable(
                factory.deployAndInitialize(
                    address(implementation),
                    TREASURY,
                    address(this),
                    usdc,
                    oversizedSeed,
                    _initCalldata()
                )
            )
        );

        // only minAssets was consumed, the rest came back to the caller
        assertEq(vault.getMinAssets(), minAssets);
        assertEq(usdc.balanceOf(address(this)), oversizedSeed - minAssets);
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    // =========================================
    // user flow on the live stack
    // =========================================

    function testDepositAndRedeem() public {
        Rebalancer vault = _deployVaultAtomically();

        deal(address(usdc), alice, THOUSAND);
        uint256 previewed = vault.previewDeposit(THOUSAND);

        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        uint256 shares = vault.deposit(THOUSAND, alice);
        vm.stopPrank();

        assertEq(shares, previewed);
        assertEq(usdc.balanceOf(alice), 0);
        assertGe(vault.totalAssets(), THOUSAND + minAssets - 5);

        skip(10 seconds);
        vm.roll(block.number + 1);

        // redeem closes the position cleanly (withdraw can round by a share);
        // 10s of Compound interest means alice gets back slightly more
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGe(assets, THOUSAND);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testRebalanceBetweenProviders() public {
        Rebalancer vault = _deployVaultAtomically();

        deal(address(usdc), alice, THOUSAND);
        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        vault.deposit(THOUSAND, alice);
        vm.stopPrank();

        // read the role id before pranking: the view call would consume the prank
        bytes32 executorRole = vault.EXECUTOR_ROLE();
        vm.prank(TREASURY);
        vault.grantRole(executorRole, keeper);

        // the entry provider holds alice's deposit plus the seed shares
        uint256 atEntry = compoundV3Provider.getDepositBalance(
            address(vault),
            vault
        );
        assertApproxEqAbs(atEntry, THOUSAND + minAssets, 5);

        uint256[] memory amounts = new uint256[](2);
        IProvider[] memory sources = new IProvider[](2);
        IProvider[] memory destinations = new IProvider[](2);

        // Compound -> Aave, then Compound -> Steakhouse Morpho
        amounts[0] = THOUSAND / 2;
        sources[0] = IProvider(address(compoundV3Provider));
        destinations[0] = IProvider(address(aaveV3Provider));
        amounts[1] = type(uint256).max; // remainder
        sources[1] = IProvider(address(compoundV3Provider));
        destinations[1] = IProvider(address(steakhouseProvider));

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        assertTrue(vault.rebalance(amounts, sources, destinations));

        assertEq(
            compoundV3Provider.getDepositBalance(address(vault), vault),
            0
        );
        assertGe(
            aaveV3Provider.getDepositBalance(address(vault), vault),
            THOUSAND / 2 - 2
        );
        assertGt(
            steakhouseProvider.getDepositBalance(address(vault), vault),
            0
        );
        // rebalancing must not destroy assets (providers round by a unit or two)
        assertApproxEqAbs(vault.totalAssets(), totalBefore, 5);
    }

    function testWithdrawAfterRebalance() public {
        Rebalancer vault = _deployVaultAtomically();

        deal(address(usdc), alice, THOUSAND);
        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        uint256 shares = vault.deposit(THOUSAND, alice);
        vm.stopPrank();

        // read the role id before pranking: the view call would consume the prank
        bytes32 executorRole = vault.EXECUTOR_ROLE();
        vm.prank(TREASURY);
        vault.grantRole(executorRole, keeper);

        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sources = new IProvider[](1);
        IProvider[] memory destinations = new IProvider[](1);
        amounts[0] = type(uint256).max;
        sources[0] = IProvider(address(compoundV3Provider));
        destinations[0] = IProvider(address(smokehouseProvider));

        vm.prank(keeper);
        vault.rebalance(amounts, sources, destinations);

        // alice exits fully while her assets sit in a Morpho vault
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assets, THOUSAND, 2);
        assertEq(usdc.balanceOf(alice), assets);
    }
}
