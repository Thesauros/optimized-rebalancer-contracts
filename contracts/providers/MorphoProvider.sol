// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";
import {IMetaMorpho} from "../interfaces/morpho/IMetaMorpho.sol";
import {IMorpho, Id, MarketParams, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title MorphoProvider
 * @notice Provider implementation for Morpho Blue protocol integration
 * @dev This provider integrates with Morpho Blue's MetaMorpho vaults to provide
 *      yield generation through automated market making and lending strategies.
 * 
 * @custom:architecture The provider works with MetaMorpho vaults that:
 * - Automatically allocate funds across multiple Morpho Blue markets
 * - Optimize yield through dynamic rebalancing
 * - Handle complex market interactions transparently
 * 
 * @custom:yield-calculation The APY calculation considers:
 * - Individual market rates from Interest Rate Models (IRM)
 * - Market utilization rates
 * - Protocol fees
 * - Asset allocation across markets
 * 
 * @custom:security Features:
 * - Uses MetaMorpho's battle-tested vault strategies
 * - Leverages Morpho Blue's peer-to-peer lending model
 * - Implements proper access controls through IProvider interface
 * 
 * @custom:usage Example:
 * ```solidity
 * // Deploy with a MetaMorpho vault address
 * MorphoProvider provider = new MorphoProvider(metaMorphoVaultAddress);
 * 
 * // The vault can now deposit/withdraw through this provider
 * provider.deposit(amount, vault);
 * uint256 balance = provider.getDepositBalance(user, vault);
 * uint256 apy = provider.getDepositRate(vault);
 * ```
 */
contract MorphoProvider is IProvider {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    /// @notice The MetaMorpho vault contract that manages the lending strategy
    /// @dev This vault automatically allocates funds across multiple Morpho Blue markets
    IMetaMorpho private immutable _metaMorpho;

    /**
     * @notice Initializes the MorphoProvider with a MetaMorpho vault
     * @param metaMorpho_ The address of the MetaMorpho vault contract
     * @dev The MetaMorpho vault must be a valid ERC4626-compatible vault
     * @dev The vault should be configured with appropriate market strategies
     */
    constructor(address metaMorpho_) {
        _metaMorpho = IMetaMorpho(metaMorpho_);
    }

    /**
     * @notice Deposits assets into the MetaMorpho vault
     * @param amount The amount of assets to deposit
     * @param vault The vault contract calling this function
     * @return success Always returns true if the deposit succeeds
     * 
     * @dev The MetaMorpho vault will automatically allocate the deposited assets
     *      across its configured markets based on the current strategy
     * @dev This function should be called via delegatecall from the vault context
     */
    function deposit(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        _metaMorpho.deposit(amount, address(vault));
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IVault vault
    ) external override returns (bool success) {
        _metaMorpho.withdraw(amount, address(vault), address(vault));
        success = true;
    }

    /**
     * @notice Returns the underlying Morpho Blue contract
     * @return The IMorpho interface for the Morpho Blue protocol
     * @dev This is used to interact with individual markets and get market data
     */
    function _getMorpho() internal view returns (IMorpho) {
        return _metaMorpho.MORPHO();
    }

    /**
     * @notice Calculates the current APY for a specific Morpho Blue market
     * @param marketParams The market parameters (collateral, loan, oracle, IRM)
     * @param market The current market state (fee, total supply, total borrow)
     * @return marketRate The calculated market rate in ray (1e27) format
     * 
     * @dev The calculation considers:
     * - Borrow rate from the Interest Rate Model (IRM)
     * - Market utilization (borrow/supply ratio)
     * - Protocol fee
     * - Compounding over 365 days
     * 
     * @dev Formula: borrowRate * (1 - fee) * utilization
     * @dev Returns 0 if IRM is not set (invalid market)
     */
    function _getMarketRate(
        MarketParams memory marketParams,
        Market memory market
    ) internal view returns (uint256 marketRate) {
        IMorpho morpho = _getMorpho();

        uint256 borrowRate;
        if (marketParams.irm == address(0)) {
            return 0;
        } else {
            borrowRate = IIrm(marketParams.irm)
                .borrowRateView(marketParams, market)
                .wTaylorCompounded(365 days);
        }

        (uint256 totalSupplyAssets, , uint256 totalBorrowAssets, ) = morpho
            .expectedMarketBalances(marketParams);

        uint256 utilization = totalBorrowAssets == 0
            ? 0
            : totalBorrowAssets.wDivUp(totalSupplyAssets);

        marketRate = borrowRate.wMulDown(1e18 - market.fee).wMulDown(
            utilization
        );
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositBalance(
        address user,
        IVault
    ) external view override returns (uint256 balance) {
        uint256 shares = _metaMorpho.balanceOf(user);
        balance = _metaMorpho.convertToAssets(shares);
    }

    /**
     * @notice Calculates the weighted average APY across all markets in the MetaMorpho vault
     * @return rate The weighted average APY in ray (1e27) format
     * 
     * @dev The calculation:
     * 1. Iterates through all markets in the vault's withdraw queue
     * 2. Calculates individual market rates using _getMarketRate()
     * 3. Weights each rate by the assets allocated to that market
     * 4. Applies the vault's fee to get the net rate
     * 5. Scales from 1e18 to 1e27 to match IProvider specification
     * 
     * @dev Formula: Σ(marketRate * assetsInMarket) * (1 - vaultFee) / totalAssets * 1e9
     */
    function getDepositRate(
        IVault
    ) external view override returns (uint256 rate) {
        IMorpho morpho = _getMorpho();

        uint256 ratio;
        uint256 queueLength = _metaMorpho.withdrawQueueLength();

        uint256 totalDeposits = _metaMorpho.totalAssets();

        for (uint256 i; i < queueLength; i++) {
            Id idMarket = _metaMorpho.withdrawQueue(i);

            MarketParams memory marketParams = morpho.idToMarketParams(
                idMarket
            );
            Market memory market = morpho.market(idMarket);

            uint256 marketRate = _getMarketRate(marketParams, market);
            uint256 assetsInMarket = morpho.expectedSupplyAssets(
                marketParams,
                address(_metaMorpho)
            );
            ratio += marketRate.wMulDown(assetsInMarket);
        }
        // Scaled by 1e9 to return ray(1e27) per IProvider specs, Morpho Blue uses base 1e18 number.
        rate =
            ratio.mulDivDown(1e18 - _metaMorpho.fee(), totalDeposits) *
            10 ** 9;
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address,
        address,
        address
    ) external view override returns (address source) {
        source = address(_metaMorpho);
    }

    /**
     * @inheritdoc IProvider
     */
    function getIdentifier() public pure override returns (string memory) {
        return "Morpho_Provider";
    }
}
