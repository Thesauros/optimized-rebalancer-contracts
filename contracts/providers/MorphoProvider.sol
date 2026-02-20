// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";
import {IMetaMorpho} from "../interfaces/morpho/IMetaMorpho.sol";
import {IMorpho, Id, MarketParams, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";

/// @title MorphoProvider
/// @notice Provider implementation for Morpho protocol integration.
contract MorphoProvider is IProvider {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    /// @dev The address is zero.
    error AddressZero();

    IMetaMorpho private immutable _metaMorpho;

    /// @dev Initializes the MorphoProvider with the specified parameters.
    /// @param metaMorpho_ The address of the MetaMorpho vault.
    constructor(address metaMorpho_) {
        if (metaMorpho_ == address(0)) {
            revert AddressZero();
        }
        _metaMorpho = IMetaMorpho(metaMorpho_);
    }

    /// @inheritdoc IProvider
    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success) {
        _metaMorpho.deposit(amount, address(vault));
        success = true;
    }

    /// @inheritdoc IProvider
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success) {
        _metaMorpho.withdraw(amount, address(vault), address(vault));
        success = true;
    }

    /// @dev Returns the Morpho contract of Morpho.
    /// @return The Morpho contract.
    function _getMorpho() internal view returns (IMorpho) {
        return _metaMorpho.MORPHO();
    }

    /// @dev Returns the current APY of a market.
    /// @param marketParams The market parameters.
    /// @param market The market.
    /// @return marketRate The market APY.
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

    /// @inheritdoc IProvider
    function getDepositBalance(
        address user,
        IRebalancer
    ) external view returns (uint256 balance) {
        uint256 shares = _metaMorpho.balanceOf(user);
        balance = _metaMorpho.convertToAssets(shares);
    }

    /// @inheritdoc IProvider
    function getDepositRate(
        IRebalancer
    ) external view returns (uint256 rate) {
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
        // scaled by 1e9 to return ray(1e27) per IProvider specs, Morpho uses base 1e18 number.
        rate =
            ratio.mulDivDown(1e18 - _metaMorpho.fee(), totalDeposits) *
            10 ** 9;
    }

    /// @inheritdoc IProvider
    function getSource(
        address,
        address,
        address
    ) external view returns (address source) {
        source = address(_metaMorpho);
    }

    /// @inheritdoc IProvider
    function getIdentifier() external pure returns (string memory) {
        return "Morpho_Provider";
    }
}
