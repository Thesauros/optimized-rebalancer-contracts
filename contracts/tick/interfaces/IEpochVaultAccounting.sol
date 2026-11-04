// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IEpochVaultAccounting
 * @notice The hub-vault surface the TickAccountant binds snapshots to.
 */
interface IEpochVaultAccounting {
    /// @notice Hub accounting state as of the end of `blockNumber`.
    struct Checkpoint {
        uint64 blockNumber;
        uint128 cash;
        uint128 pendingDeposits;
        uint128 liabilities;
        uint128 totalSupply;
    }

    function checkpointCount() external view returns (uint256);

    function checkpointAt(uint256 index) external view returns (Checkpoint memory);

    function totalSupply() external view returns (uint256);

    function mintFeeShares(address to, uint256 shares) external;
}
