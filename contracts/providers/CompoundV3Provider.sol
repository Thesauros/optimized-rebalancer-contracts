// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {IProviderManager} from "../interfaces/IProviderManager.sol";
import {CometInterface} from "../interfaces/compoundV3/CometInterface.sol";

/// @title CompoundV3Provider
/// @notice Provider implementation for Compound V3 (Comet) protocol integration.
contract CompoundV3Provider is IProvider {
    /// @dev The address is zero.
    error AddressZero();

    IProviderManager private immutable _providerManager;

    /// @dev Initializes the CompoundV3Provider with the specified parameters.
    /// @param providerManager_ The ProviderManager contract.
    constructor(address providerManager_) {
        if (providerManager_ == address(0)) {
            revert AddressZero();
        }
        _providerManager = IProviderManager(providerManager_);
    }

    /// @inheritdoc IProvider
    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success) {
        CometInterface comet = _getComet(vault);
        comet.supply(vault.asset(), amount);
        success = true;
    }

    /// @inheritdoc IProvider
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success) {
        CometInterface comet = _getComet(vault);
        comet.withdraw(vault.asset(), amount);
        success = true;
    }

    /// @dev Returns the Comet contract of Compound V3 for the specified vault.
    /// @param vault The vault.
    /// @return The Comet contract.
    function _getComet(
        IRebalancer vault
    ) internal view returns (CometInterface) {
        address comet = _providerManager.getYieldToken(
            getIdentifier(),
            vault.asset()
        );
        return CometInterface(comet);
    }

    /// @inheritdoc IProvider
    function getDepositBalance(
        address user,
        IRebalancer vault
    ) external view returns (uint256 balance) {
        CometInterface comet = _getComet(vault);
        balance = comet.balanceOf(user);
    }

    /// @inheritdoc IProvider
    function getDepositRate(
        IRebalancer vault
    ) external view returns (uint256 rate) {
        CometInterface comet = _getComet(vault);
        uint256 utilization = comet.getUtilization();
        // scaled by 1e9 to return ray(1e27) per IProvider specs, Compound uses base 1e18 number.
        uint256 ratePerSecond = comet.getSupplyRate(utilization) * 10 ** 9;
        // 31536000 seconds in a year = 60 * 60 * 24 * 365.
        rate = ratePerSecond * 31536000;
    }

    /// @inheritdoc IProvider
    function getSource(
        address asset,
        address,
        address
    ) external view returns (address source) {
        source = _providerManager.getYieldToken(getIdentifier(), asset);
    }

    /// @notice Returns the ProviderManager contract.
    /// @return The ProviderManager contract.
    function getProviderManager() external view returns (IProviderManager) {
        return _providerManager;
    }

    /// @inheritdoc IProvider
    function getIdentifier() public pure returns (string memory) {
        return "Compound_V3_Provider";
    }
}
