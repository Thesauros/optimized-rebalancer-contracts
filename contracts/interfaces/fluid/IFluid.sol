// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Fluid lending fToken: ERC4626 over the Liquidity layer.
interface IFluidFToken is IERC4626 {
    function getData()
        external
        view
        returns (
            address liquidity,
            address lendingFactory,
            address lendingRewardsRateModel,
            address permit2,
            address rebalancer,
            bool rewardsActive,
            uint256 liquidityBalance,
            uint256 liquidityExchangePrice,
            uint256 tokenExchangePrice
        );

    function minDeposit() external view returns (uint256);
}

/// @notice Fluid Liquidity layer: its packed state is read through readFromStorage.
interface IFluidLiquidity {
    function readFromStorage(bytes32 slot) external view returns (uint256);
}
