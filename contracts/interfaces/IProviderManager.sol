// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IProviderManager
 */
interface IProviderManager {
    /**
     * @dev Emitted when the yield token is set for an asset.
     * @param identifier The identifier of the provider.
     * @param asset The address of the asset.
     * @param yieldToken The address of the corresponding yield token.
     */
    event YieldTokenUpdated(
        string identifier,
        address indexed asset,
        address yieldToken
    );

    /**
     * @dev Emitted when the market is set for two assets.
     * @param identifier The identifier of the provider.
     * @param assetOne The address of the first asset.
     * @param assetTwo The address of the second asset.
     * @param market The address of the corresponding market.
     */
    event MarketUpdated(
        string identifier,
        address indexed assetOne,
        address indexed assetTwo,
        address market
    );

    /**
     * @notice Returns the yield token for a given asset and provider identifier.
     * @param identifier The identifier of the provider.
     * @param asset The address of the asset.
     */
    function getYieldToken(
        string memory identifier,
        address asset
    ) external view returns (address yieldToken);

    /**
     * @notice Returns the market for two assets and a provider identifier.
     * @param identifier The identifier of the provider.
     * @param assetOne The address of the first asset.
     * @param assetTwo The address of the second asset.
     */
    function getMarket(
        string memory identifier,
        address assetOne,
        address assetTwo
    ) external view returns (address market);

    /**
     * @notice Sets the yield token for a given asset and provider identifier.
     * @param identifier The identifier of the provider.
     * @param asset The address of the asset.
     * @param yieldToken The address of the corresponding yield token.
     */
    function setYieldToken(
        string memory identifier,
        address asset,
        address yieldToken
    ) external;

    /**
     * @notice Sets the market for two assets and a provider identifier.
     * @param identifier The identifier of the provider.
     * @param assetOne The address of the first asset.
     * @param assetTwo The address of the second asset.
     * @param market The address of the corresponding market.
     */
    function setMarket(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) external;
}
