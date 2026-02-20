// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProviderManager} from "../interfaces/IProviderManager.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ProviderManager
/// @notice Stores provider-specific configurations.
contract ProviderManager is Ownable2Step, IProviderManager {
    /// @dev identifier => asset address => yield token address
    mapping(string => mapping(address => address)) private _assetToYieldToken;

    /// @dev identifier => assetOne => assetTwo => market.
    mapping(string => mapping(address => mapping(address => address)))
        private _assetsToMarket;

    mapping(string => bool) private _identifierRegistered;

    string[] private _providerIdentifiers;

    /// @dev Initializes the ProviderManager with the specified parameters.
    /// @param owner_ The address of the initial owner.
    constructor(address owner_) Ownable(owner_) {}

    /// @inheritdoc IProviderManager
    function setYieldToken(
        string memory identifier,
        address asset,
        address yieldToken
    ) external onlyOwner {
        if (!_identifierRegistered[identifier]) {
            _identifierRegistered[identifier] = true;
            _providerIdentifiers.push(identifier);
        }
        _assetToYieldToken[identifier][asset] = yieldToken;
        emit YieldTokenUpdated(identifier, asset, yieldToken);
    }

    /// @inheritdoc IProviderManager
    function setMarket(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) external onlyOwner {
        if (!_identifierRegistered[identifier]) {
            _identifierRegistered[identifier] = true;
            _providerIdentifiers.push(identifier);
        }
        _assetsToMarket[identifier][assetOne][assetTwo] = market;
        emit MarketUpdated(identifier, assetOne, assetTwo, market);
    }

    /// @inheritdoc IProviderManager
    function getYieldToken(
        string memory identifier,
        address asset
    ) external view returns (address) {
        return _assetToYieldToken[identifier][asset];
    }

    /// @inheritdoc IProviderManager
    function getMarket(
        string memory identifier,
        address assetOne,
        address assetTwo
    ) external view returns (address) {
        return _assetsToMarket[identifier][assetOne][assetTwo];
    }

    /// @inheritdoc IProviderManager
    function getIdentifiers() external view returns (string[] memory) {
        return _providerIdentifiers;
    }
}
