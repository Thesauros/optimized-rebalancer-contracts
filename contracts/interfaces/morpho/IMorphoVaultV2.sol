// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Subset of the Morpho Vault V2 interface used by the provider.
interface IMorphoVaultV2 is IERC4626 {
    function adaptersLength() external view returns (uint256);
    function adapters(uint256 index) external view returns (address);
    function maxRate() external view returns (uint64);
    function performanceFee() external view returns (uint96);
    /// @notice Management fee per second, scaled by 1e18 (not annualized).
    function managementFee() external view returns (uint96);
    function accrueInterestView()
        external
        view
        returns (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares);
}

interface IMorphoV2Adapter {
    function realAssets() external view returns (uint256);
}

interface IMorphoVaultV1Adapter is IMorphoV2Adapter {
    function morphoVaultV1() external view returns (address);
}

/// @notice The V2 market adapter tracks its own shares, excluding donations.
interface IMorphoMarketV1AdapterV2 is IMorphoV2Adapter {
    function morpho() external view returns (address);
    function marketIdsLength() external view returns (uint256);
    function marketIds(uint256 index) external view returns (bytes32);
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}
