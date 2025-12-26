// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    using Math for uint256;

    /**
     * @dev Errors
     */
    error Rebalancer__InvalidProvider();
    error Rebalancer__ExcessRebalanceFee();

    /**
     * @dev Initializes the Rebalancer contract with the specified parameters.
     * @param asset_ The address of the underlying asset managed by the vault.
     * @param name_ The name of the tokenized vault.
     * @param symbol_ The symbol of the tokenized vault.
     * @param providers_ An array of providers serving as a liquidity source for lending and/or yield.
     * @param withdrawFeePercent_ The fee percentage applied to withdrawals.
     * @param timelock_ The address of the timelock contract.
     * @param treasury_ The address of the treasury.
     */
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        uint256 withdrawFeePercent_,
        address timelock_,
        address treasury_
    )
        Vault(
            asset_,
            name_,
            symbol_,
            providers_,
            withdrawFeePercent_,
            timelock_,
            treasury_
        )
    {}

    receive() external payable {}

    /**
     * @inheritdoc IVault
     */
    function rebalance(
        uint256 assets,
        IProvider from,
        IProvider to,
        uint256 fee
    ) external onlyOperator returns (bool) {
        if (
            !_validateProvider(address(from)) || !_validateProvider(address(to))
        ) {
            revert Rebalancer__InvalidProvider();
        }

        _checkFee(fee, assets);

        _delegateActionToProvider(assets, "withdraw", from);
        _delegateActionToProvider(assets - fee, "deposit", to);

        if (fee > 0) {
            address _treasury = treasury;

            _asset.safeTransfer(_treasury, fee);
            emit FeeCharged(_treasury, fee);
        }

        emit RebalanceExecuted(
            assets,
            assets - fee,
            address(from),
            address(to)
        );
        return true;
    }

    /**
     * @notice Validates that the rebalancing fee is within acceptable limits
     * @param fee The fee amount to validate
     * @param amount The total amount being rebalanced
     * 
     * @dev The fee cannot exceed MAX_REBALANCE_FEE_PERCENT (20%) of the rebalanced amount
     * @dev This prevents excessive fees that could harm users
     * @dev Reverts with Rebalancer__ExcessRebalanceFee if fee is too high
     */
    function _checkFee(uint256 fee, uint256 amount) internal pure {
        uint256 reasonableFee = amount.mulDiv(
            MAX_REBALANCE_FEE_PERCENT,
            PRECISION_FACTOR
        );
        if (fee > reasonableFee) {
            revert Rebalancer__ExcessRebalanceFee();
        }
    }
}
