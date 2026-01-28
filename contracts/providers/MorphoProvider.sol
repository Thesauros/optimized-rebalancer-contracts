// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";
import {IMetaMorpho} from "../interfaces/morpho/IMetaMorpho.sol";
import {IMorpho, Id, MarketParams, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";

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

    IMetaMorpho private immutable _metaMorpho;

    constructor(address metaMorpho_) {
        _metaMorpho = IMetaMorpho(metaMorpho_);
    }

    /**
     * @inheritdoc IProvider
     */
    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _metaMorpho.deposit(amount, address(vault));
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _metaMorpho.withdraw(amount, address(vault), address(vault));
        success = true;
    }

    /**
     * @dev Returns the Morpho contract of Morpho Blue.
     */
    function _getMorpho() internal view returns (IMorpho) {
        return _metaMorpho.MORPHO();
    }

    /**
     * @dev Returns the current APY of a Morpho Blue market.
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
        IRebalancer
    ) external view override returns (uint256 balance) {
        uint256 shares = _metaMorpho.balanceOf(user);
        balance = _metaMorpho.convertToAssets(shares);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(
        IRebalancer
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
