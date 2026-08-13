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
    error InsufficientLiquidity();
    /// @notice Thrown by `setProviders`/`_setProviders` when the proposed new provider
    /// list would drop the vault's current entry provider (see Finding 5).
    error EntryProviderNotInProviders();

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
     * @notice Emitted when `_setProviders` fails to revoke this vault's stale ERC20
     * approval for a provider that is being removed from the provider list (e.g. because
     * the removed provider's `getSource()` itself reverts). The provider is still removed
     * from the list; only the approval revocation for its `source` address failed.
     *
     * @param provider The provider whose stale approval could not be revoked.
     */
    event StaleApprovalRevokeFailed(address indexed provider);

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
     * @param lastTotalBalance The previous recorded total balance.
     * @param currentTotalBalance The current total balance.
     * @param performanceFeeShares The amount of shares minted as performance fee.
     * @param managementFeeShares The amount of shares minted as management fee.
     */
    event FeesApplied(
        uint256 lastTotalBalance,
        uint256 currentTotalBalance,
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
}
