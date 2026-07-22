// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IProvider} from "./IProvider.sol";

interface IRebalancer is IERC4626 {
    /// @dev The address is zero.
    error AddressZero();

    /// @dev One or more input values are out of bounds.
    error InvalidInput();

    /// @dev The asset amount is below the required minimum.
    error AssetsBelowMin();

    /// @dev The count is zero.
    error InvalidCount();

    /// @dev Array lengths do not match.
    error ArrayMismatch();

    /// @dev The provider is not listed.
    error InvalidProvider();
    error InsufficientLiquidity();

    /// @dev Emitted when the listed providers are updated.
    /// @param providers The new listed providers.
    event ProvidersUpdated(IProvider[] providers);

    /// @dev Emitted when the entry provider is updated.
    /// @param entryProvider The new entry provider.
    event EntryProviderUpdated(IProvider entryProvider);

    /// @dev Emitted when the timelock address is updated.
    /// @param timelock The new timelock address.
    event TimelockUpdated(address indexed timelock);

    /// @dev Emitted when the treasury address is updated.
    /// @param treasury The new treasury address.
    event TreasuryUpdated(address indexed treasury);

    /// @dev Emitted when the management fee rate is updated.
    /// @param managementFee The new management fee rate.
    event ManagementFeeUpdated(uint96 managementFee);

    /// @dev Emitted when the performance fee rate is updated.
    /// @param performanceFee The new performance fee rate.
    event PerformanceFeeUpdated(uint96 performanceFee);

    /// @dev Emitted when the minimum asset amount is updated.
    /// @param minAssets The new minimum asset amount.
    event MinAssetsUpdated(uint256 minAssets);

    /// @dev Emitted when fees are applied.
    /// @param lastTotalAssets The last recorded total managed assets.
    /// @param totalManagedAssets The current total managed assets.
    /// @param performanceFeeShares The performance fee shares minted.
    /// @param managementFeeShares The management fee shares minted.
    event FeesApplied(
        uint256 lastTotalAssets,
        uint256 totalManagedAssets,
        uint256 performanceFeeShares,
        uint256 managementFeeShares
    );

    /// @dev Emitted when assets are rebalanced across providers.
    /// @param assets The amount of assets.
    /// @param from The provider assets are withdrawn from.
    /// @param to The provider assets are deposited to.
    event RebalanceExecuted(
        uint256 assets,
        address indexed from,
        address indexed to
    );

    /// @notice Rebalances assets across providers.
    /// @dev Caller must have the executor role.
    /// @dev If an amount is set to max, the full balance at the source provider is used.
    /// @param amounts The asset amounts to rebalance.
    /// @param sources The providers to withdraw assets from.
    /// @param destinations The providers to deposit assets to.
    /// @return True if the rebalance succeeds.
    function rebalance(
        uint256[] memory amounts,
        IProvider[] memory sources,
        IProvider[] memory destinations
    ) external returns (bool);

    /// @notice Mints accrued fee shares and updates fee snapshots.
    function applyFees() external;

    /// @notice Sets the listed providers.
    /// @dev Caller must be the timelock.
    /// @param providers The new listed providers.
    function setProviders(IProvider[] memory providers) external;

    /// @notice Sets the entry provider.
    /// @dev Caller must have the admin role.
    /// @param entryProvider The new entry provider.
    function setEntryProvider(IProvider entryProvider) external;

    /// @notice Sets the timelock address.
    /// @dev Caller must be the timelock.
    /// @param timelock The new timelock address.
    function setTimelock(address timelock) external;

    /// @notice Sets the treasury address.
    /// @dev Caller must have the admin role.
    /// @param treasury The new treasury address.
    function setTreasury(address treasury) external;

    /// @notice Sets the management fee rate.
    /// @dev Caller must have the admin role.
    /// @param managementFee The new management fee rate.
    function setManagementFee(uint96 managementFee) external;

    /// @notice Sets the performance fee rate.
    /// @dev Caller must have the admin role.
    /// @param performanceFee The new performance fee rate.
    function setPerformanceFee(uint96 performanceFee) external;

    /// @notice Sets the minimum asset amount.
    /// @dev Caller must have the admin role.
    /// @param minAssets The new minimum asset amount.
    function setMinAssets(uint256 minAssets) external;

    /// @notice Returns the accrued fee shares.
    /// @return performanceFeeShares The accrued performance fee shares.
    /// @return managementFeeShares The accrued management fee shares.
    function getAccruedFees() external view returns (uint256, uint256);

    /// @notice Returns the listed providers.
    /// @return The listed providers.
    function getProviders() external view returns (IProvider[] memory);

    /// @notice Returns the entry provider.
    /// @return The entry provider.
    function getEntryProvider() external view returns (IProvider);

    /// @notice Returns the timelock address.
    /// @return The timelock address.
    function getTimelock() external view returns (address);

    /// @notice Returns the treasury address.
    /// @return The treasury address.
    function getTreasury() external view returns (address);

    /// @notice Returns the management fee rate.
    /// @return The management fee rate.
    function getManagementFee() external view returns (uint96);

    /// @notice Returns the performance fee rate.
    /// @return The performance fee rate.
    function getPerformanceFee() external view returns (uint96);

    /// @notice Returns the last recorded total managed assets.
    /// @return The last recorded total managed assets.
    function getLastTotalAssets() external view returns (uint256);

    /// @notice Returns the last recorded timestamp.
    /// @return The last recorded timestamp.
    function getLastTimestamp() external view returns (uint64);

    /// @notice Returns the minimum asset amount.
    /// @return The minimum asset amount.
    function getMinAssets() external view returns (uint256);
}
