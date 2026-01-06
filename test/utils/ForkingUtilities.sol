// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IVault} from "../../contracts/interfaces/IVault.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {Timelock} from "../../contracts/Timelock.sol";
import {VaultManager} from "../../contracts/VaultManager.sol";
import {ProviderManager} from "../../contracts/providers/ProviderManager.sol";
import {CompoundV3Provider} from "../../contracts/providers/CompoundV3Provider.sol";
import {AaveV3Provider} from "../../contracts/providers/AaveV3Provider.sol";
import {Test} from "forge-std/Test.sol";

contract ForkingUtilities is Test {
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public initializer = makeAddr("initializer");
    address public treasury = makeAddr("treasury");

    Rebalancer public vault;
    Timelock public timelock;

    ProviderManager public providerManager;

    IERC20 public usdc;
    IERC20 public usdt;

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

    uint256 public constant PRECISION_FACTOR = 1 ether;
    uint256 public constant WITHDRAW_FEE_PERCENT = 0.001 ether; // 0.1%

    uint256 public constant MIN_AMOUNT = 1e6;
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;
    uint256 public constant TIMELOCK_DELAY = 30 minutes;

    constructor() {
        string memory ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");
        vm.createSelectFork(ARBITRUM_RPC_URL);

        usdt = IERC20(USDT_ADDRESS);
        vm.label(address(usdt), "USDT");

        usdc = IERC20(USDC_ADDRESS);
        vm.label(address(usdc), "USDC");

        providerManager = new ProviderManager(address(this));
        providerManager.setYieldToken(
            "Compound_V3_Provider",
            USDT_ADDRESS,
            COMET_USDT_ADDRESS
        );

        timelock = new Timelock(address(this), TIMELOCK_DELAY);
    }

    function deployVault(
        address _asset,
        IProvider[] memory _providers
    ) internal {
        string memory name = string.concat(
            "Rebalance ",
            IERC20Metadata(_asset).name()
        );
        string memory symbol = string.concat(
            "r",
            IERC20Metadata(_asset).symbol()
        );

        vault = new Rebalancer(
            _asset,
            name,
            symbol,
            _providers,
            WITHDRAW_FEE_PERCENT,
            address(timelock),
            treasury
        );
    }

    function initializeVault(
        IVault _vault,
        uint256 _amount,
        address _from
    ) internal {
        address asset = _vault.asset();

        deal(asset, _from, _amount);

        vm.startPrank(_from);
        IERC20(asset).approve(address(_vault), _amount);
        _vault.setupVault(_amount);
        vm.stopPrank();
    }

    function executeDeposit(
        IVault _vault,
        uint256 _amount,
        address _from
    ) internal {
        address asset = _vault.asset();

        deal(asset, _from, _amount);

        vm.startPrank(_from);
        IERC20(asset).approve(address(_vault), _amount);
        _vault.deposit(_amount, _from);
        vm.stopPrank();
    }

    function executeWithdraw(
        IVault _vault,
        uint256 _amount,
        address _from
    ) internal {
        vm.prank(_from);
        _vault.withdraw(_amount, _from, _from);
    }

    function executeRedeem(
        IVault _vault,
        uint256 _amount,
        address _from
    ) internal {
        vm.prank(_from);
        _vault.redeem(_amount, _from, _from);
    }
}
