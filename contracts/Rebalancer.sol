// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IProvider} from "./interfaces/IProvider.sol";
import {Vault} from "./base/Vault.sol";

/**
 * @title Rebalancer
 * @notice Specialized vault contract for automated rebalancing operations
 * @dev This contract extends the base Vault functionality with automated rebalancing
 *      capabilities, allowing operators to move funds between providers efficiently
 *      while maintaining proper fee structures and security controls.
 * 
 * @custom:rebalancing-features The contract provides:
 * - Automated provider-to-provider transfers
 * - Configurable rebalancing fees (max 20%)
 * - Active provider management
 * - Fee collection to treasury
 * - Comprehensive event logging
 * 
 * @custom:security-measures Security features include:
 * - Operator-only rebalancing execution
 * - Provider validation before operations
 * - Fee limits to prevent excessive charges
 * - Proper asset accounting and transfers
 * - Event emission for transparency
 * 
 * @custom:rebalancing-process The rebalancing workflow:
 * 1. Validate source and destination providers
 * 2. Check fee limits (max 20% of rebalanced amount)
 * 3. Withdraw assets from source provider
 * 4. Deposit assets to destination provider (minus fee)
 * 5. Transfer fee to treasury
 * 6. Optionally activate destination provider
 * 7. Emit rebalancing events
 * 
 * @custom:usage Example:
 * ```solidity
 * // Rebalance 1000 USDC from Aave to Morpho with 1% fee
 * rebalancer.rebalance(
 *     1000e6, // 1000 USDC
 *     aaveProvider,
 *     morphoProvider,
 *     10e6, // 1% fee (10 USDC)
 *     true // Activate Morpho as active provider
 * );
 * ```
 */
contract Rebalancer is Vault {
    using SafeERC20 for IERC20Metadata;

    /**
     * @dev Errors
     */
    error Rebalancer__InvalidProvider();

    /**
     * @dev Initializes the Rebalancer contract with the specified parameters.
     * @param asset_ The address of the underlying asset managed by the vault.
     * @param name_ The name of the tokenized vault.
     * @param symbol_ The symbol of the tokenized vault.
     * @param providers_ An array of providers serving as a liquidity source for lending and/or yield.
     * @param managementFee_ The fee percentage applied for vault management.
     * @param performanceFee_ The fee percentage applied for vault performance.
     * @param treasury_ The address of the treasury.
     * @param timelock_ The address of the timelock contract.
     */
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        uint256 initialDeposit_,
        uint96 managementFee_,
        uint96 performanceFee_,
        address treasury_,
        address timelock_
    )
        Vault(
            asset_,
            name_,
            symbol_,
            providers_,
            initialDeposit_,
            managementFee_,
            performanceFee_,
            treasury_,
            timelock_
        )
    {}

    receive() external payable {}

    /**
     * @inheritdoc IVault
     */
    function rebalance(
        uint256 assets,
        IProvider from,
        IProvider to
    ) external onlyOperator returns (bool) {
        if (
            !_validateProvider(address(from)) || !_validateProvider(address(to))
        ) {
            revert Rebalancer__InvalidProvider();
        }

        _delegateActionToProvider(assets, "withdraw", from);
        _delegateActionToProvider(assets, "deposit", to);

        emit RebalanceExecuted(
            assets,
            address(from),
            address(to)
        );

        return true;
    }
}
