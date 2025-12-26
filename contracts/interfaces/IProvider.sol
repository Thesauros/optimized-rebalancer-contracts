// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IVault} from "./IVault.sol";

/**
 * @title IProvider
 */
interface IProvider {
    /**
     * @notice Returns the identifier of the provider.
     */
    function getIdentifier() external view returns (string memory);

    /**
     * @notice Returns the source address that requires ERC20 approval for vault actions.
     *
     * @param keyOne The first key for identification
     * @param keyTwo The second key for identification
     * @param keyThree The third key for identification
     *
     * @dev Some provider implementations may not require all keys.
     */
    function getSource(
        address keyOne,
        address keyTwo,
        address keyThree
    ) external view returns (address source);

    /**
     * @notice Performs a deposit at the provider on behalf of a vault.
     *
     * @param amount The amount to deposit.
     * @param vault The vault calling this function.
     *
     * @dev This function should be delegate called in the context of a vault.
     */
    function deposit(
        uint256 amount,
        IVault vault
    ) external returns (bool success);

    /**
     * @notice Performs a withdraw at the provider on behalf of a vault.
     *
     * @param amount The amount to withdraw.
     * @param vault The vault calling this function.
     *
     * @dev This function should be delegate called in the context of a vault.
     */
    function withdraw(
        uint256 amount,
        IVault vault
    ) external returns (bool success);

    /**
     * @notice Returns the deposit balance of a user at the provider.
     *
     * @param user The address of the user whose balance is needed.
     * @param vault The vault required by specific providers with multi-markets; otherwise, pass address(0).
     */
    function getDepositBalance(
        address user,
        IVault vault
    ) external view returns (uint256 balance);

    /**
     * @notice Returns the latest supply annual percentage rate (APR) at the provider.
     *
     * @param vault The vault required by specific provider with multi-markets; otherwise, pass address(0).
     *
     * @dev Must return the rate in ray units (1e27).
     */
    function getDepositRate(IVault vault) external view returns (uint256 rate);
}
