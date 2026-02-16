// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "./IERC4626.sol";
import {IProvider} from "./IProvider.sol";

/**
 * @title IRebalancer
 */
interface IRebalancer is IERC4626 {
    error AddressZero();
    error InvalidInput();
    error AssetsBelowMin();
    error InvalidCount();
    error ArrayMismatch();
    error InvalidProvider();

    /**
     * @notice Emitted when the timelock contract is changed.
     *
     * @param timelock The new timelock contract address.
     */
    event TimelockUpdated(address indexed timelock);

    /**
     * @notice Emitted when the available providers for the vault change.
     *
     * @param providers The new array of providers.
     */
    event ProvidersUpdated(IProvider[] providers);

    /**
     * @notice Emitted when the entry provider is changed.
     *
     * @param entryProvider The new entry provider.
     */
    event EntryProviderUpdated(IProvider entryProvider);

    /**
     * @notice Emitted when the treasury address is changed.
     *
     * @param treasury The new treasury address.
     */
    event TreasuryUpdated(address indexed treasury);

    /**
     * @notice Emitted when the performance fee percentage is changed.
     *
     * @param performanceFee The new performance fee percentage.
     */
    event PerformanceFeeUpdated(uint256 performanceFee);

    /**
     * @notice Emitted when the management fee percentage is changed.
     *
     * @param managementFee The new management fee percentage.
     */
    event ManagementFeeUpdated(uint256 managementFee);

    /**
     * @notice Emitted when the minimum amount is changed.
     *
     * @param minAssets The new minimum amount.
     */
    event MinAssetsUpdated(uint256 minAssets);

    /**
     * @notice Emitted when fees are applied.
     *
     * @param lastTotalAssets The previous recorded total assets.
     * @param totalManagedAssets The current total assets.
     * @param performanceFeeShares The amount of shares minted as performance fee.
     * @param managementFeeShares The amount of shares minted as management fee.
     */
    event FeesApplied(
        uint256 lastTotalAssets,
        uint256 totalManagedAssets,
        uint256 performanceFeeShares,
        uint256 managementFeeShares
    );

    /**
     * @notice Emitted when the vault is rebalanced.
     *
     * @param assets The amount of assets rebalanced.
     * @param from The provider from which assets are rebalanced.
     * @param to The provider to which assets are rebalanced.
     */
    event RebalanceExecuted(
        uint256 assets,
        address indexed from,
        address indexed to
    );

    /**
     * @notice Performs rebalancing of the vault by moving funds across providers.
     * @param amounts An array of asset amounts to be rebalanced.
     * @param sources An array of providers holding the assets.
     * @param destinations An array of providers receiving the assets.
     */
    function rebalance(
        uint256[] memory amounts,
        IProvider[] memory sources,
        IProvider[] memory destinations
    ) external returns (bool);

    function applyFees() external;

    function setProviders(IProvider[] memory providers) external;

    function setEntryProvider(IProvider entryProvider) external;

    function setTimelock(address timelock) external;

    function setTreasury(address treasury) external;

    function setManagementFee(uint96 managementFee) external;

    function setPerformanceFee(uint96 performanceFee) external;

    function setMinAssets(uint256 minAssets) external;

    function getAccruedFees() external view returns (uint256, uint256);

    function getProviders() external view returns (IProvider[] memory);

    function getEntryProvider() external view returns (IProvider);

    function getTimelock() external view returns (address);

    function getTreasury() external view returns (address);

    function getManagementFee() external view returns (uint96);

    function getPerformanceFee() external view returns (uint96);

    function getLastTotalAssets() external view returns (uint256);

    function getLastTimestamp() external view returns (uint64);

    function getMinAssets() external view returns (uint256);
}
