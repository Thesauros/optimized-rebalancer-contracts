// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IMorpho, Id, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

struct MarketAllocation {
    /// @notice The market to allocate.
    MarketParams marketParams;
    /// @notice The amount of assets to allocate.
    uint256 assets;
}

/// @title IMetaMorpho
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @dev Modified version of the original Morpho interface.
interface IMetaMorpho is IERC4626 {
    /// @notice The address of the Morpho contract.
    function MORPHO() external view returns (IMorpho);

    /// @notice The current fee.
    function fee() external view returns (uint96);

    /// @notice The current timelock.
    function timelock() external view returns (uint256);

    /// @dev Stores the order of markets on which liquidity is supplied upon deposit.
    /// @dev Can contain any market. A market is skipped as soon as its supply cap is reached.
    function supplyQueue(uint256) external view returns (Id);

    /// @notice Returns the length of the supply queue.
    function supplyQueueLength() external view returns (uint256);

    /// @dev Stores the order of markets from which liquidity is withdrawn upon withdrawal.
    /// @dev Always contain all non-zero cap markets as well as all markets on which the vault supplies liquidity,
    /// without duplicate.
    function withdrawQueue(uint256) external view returns (Id);

    /// @notice Returns the length of the withdraw queue.
    function withdrawQueueLength() external view returns (uint256);

    /// @notice Stores the total assets managed by this vault when the fee was last accrued.
    function lastTotalAssets() external view returns (uint256);

    /// @notice Stores the missing assets due to realized bad debt or forced market removal.
    /// @dev In order to cover those lost assets, it is advised to supply on behalf of address(1) on the vault
    /// (canonical method).
    function lostAssets() external view returns (uint256);
}
