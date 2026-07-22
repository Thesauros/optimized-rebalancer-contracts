// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRebalancer} from "./IRebalancer.sol";

interface IProvider {
    /// @notice Performs a deposit on behalf of a vault.
    /// @dev This function should be delegate called in the context of a vault.
    /// @param amount The amount to deposit.
    /// @param vault The vault calling this function.
    /// @return success True if the deposit succeeds, false otherwise.
    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success);

    /// @notice Performs a withdraw on behalf of a vault.
    /// @dev This function should be delegate called in the context of a vault.
    /// @param amount The amount to withdraw.
    /// @param vault The vault calling this function.
    /// @return success True if the withdrawal succeeds, false otherwise.
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external returns (bool success);

    /// @notice Returns the deposit balance of a user.
    /// @param user The address of the user.
    /// @param vault The vault required by specific providers with multi-markets; otherwise, pass address(0).
    /// @return balance The deposit balance.
    function getDepositBalance(
        address user,
        IRebalancer vault
    ) external view returns (uint256 balance);

    /// @notice Returns the latest supply annual percentage rate (APR).
    /// @dev Must return the rate in ray units (1e27).
    /// @param vault The vault required by specific providers with multi-markets; otherwise, pass address(0).
    /// @return rate The latest supply annual percentage rate.
    function getDepositRate(
        IRebalancer vault
    ) external view returns (uint256 rate);

    /// @notice Returns the source address that requires erc20 approval for vault actions.
    /// @dev Some provider implementations may not require all keys.
    /// @param keyOne The first key for identification.
    /// @param keyTwo The second key for identification.
    /// @param keyThree The third key for identification.
    /// @return source The source address.
    function getSource(
        address keyOne,
        address keyTwo,
        address keyThree
    ) external view returns (address source);

    /// @notice Returns the provider identifier.
    /// @return The provider identifier.
    function getIdentifier() external view returns (string memory);
}
