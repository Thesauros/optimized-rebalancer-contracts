// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IProviderManager {
    /// @dev Emitted when a yield token is updated.
    /// @param identifier The provider identifier.
    /// @param asset The address of the asset.
    /// @param yieldToken The address of the yield token.
    event YieldTokenUpdated(
        string identifier,
        address indexed asset,
        address yieldToken
    );

    /// @dev Emitted when a market is updated.
    /// @param identifier The provider identifier.
    /// @param assetOne The address of the first asset.
    /// @param assetTwo The address of the second asset.
    /// @param market The address of the market.
    event MarketUpdated(
        string identifier,
        address indexed assetOne,
        address indexed assetTwo,
        address market
    );

    /// @notice Sets the yield token.
    /// @dev Caller must be the owner.
    /// @param identifier The provider identifier.
    /// @param asset The address of the asset.
    /// @param yieldToken The address of the yield token.
    function setYieldToken(
        string memory identifier,
        address asset,
        address yieldToken
    ) external;

    /// @notice Sets the market.
    /// @dev Caller must be the owner.
    /// @param identifier The provider identifier.
    /// @param assetOne The address of the first asset.
    /// @param assetTwo The address of the second asset.
    /// @param market The address of the market.
    function setMarket(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) external;

    /// @notice Returns the yield token.
    /// @param identifier The provider identifier.
    /// @param asset The address of the asset.
    /// @return The address of the yield token.
    function getYieldToken(
        string memory identifier,
        address asset
    ) external view returns (address);

    /// @notice Returns the market.
    /// @param identifier The provider identifier.
    /// @param assetOne The address of the first asset.
    /// @param assetTwo The address of the second asset.
    /// @return The address of the market.
    function getMarket(
        string memory identifier,
        address assetOne,
        address assetTwo
    ) external view returns (address);

    /// @notice Returns all registered provider identifiers.
    /// @return The registered provider identifiers.
    function getIdentifiers() external view returns (string[] memory);
}
