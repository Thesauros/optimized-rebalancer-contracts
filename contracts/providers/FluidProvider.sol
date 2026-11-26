// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IFluidFToken, IFluidLiquidity} from "../interfaces/fluid/IFluid.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";

/// @notice Fluid lending (fToken) provider.
/// @dev Actions are delegatecalled by Rebalancer. Configuration MUST stay immutable.
///      Withdrawals are limited by the Liquidity layer's withdrawal limit and idle
///      balance; a withdrawal beyond them reverts natively.
contract FluidProvider is IProvider {
    /// LiquiditySlotsLink.LIQUIDITY_EXCHANGE_PRICES_MAPPING_SLOT
    uint256 private constant EXCHANGE_PRICES_SLOT = 5;
    uint256 private constant RAY = 1e27;
    /// The supply yield below is in 1e12 = 100%.
    uint256 private constant YIELD_TO_RAY = 1e15;

    IFluidFToken public immutable fToken;
    IFluidLiquidity public immutable liquidity;
    address private immutable _asset;

    error InvalidFToken();
    error InvalidVaultContext();
    error AssetMismatch();

    constructor(address fToken_) {
        if (fToken_.code.length == 0) revert InvalidFToken();
        fToken = IFluidFToken(fToken_);
        _asset = fToken.asset();
        if (_asset.code.length == 0) revert InvalidFToken();
        // getData() rejects a generic ERC4626 at deployment, before any approvals.
        (address liquidity_,,,,,,,,) = fToken.getData();
        if (liquidity_.code.length == 0) revert InvalidFToken();
        liquidity = IFluidLiquidity(liquidity_);
    }

    function deposit(uint256 amount, IRebalancer vault) external override returns (bool) {
        _checkVault(vault);
        fToken.deposit(amount, address(vault));
        return true;
    }

    function withdraw(uint256 amount, IRebalancer vault) external override returns (bool) {
        _checkVault(vault);
        fToken.withdraw(amount, address(vault), address(vault));
        return true;
    }

    function _checkVault(IRebalancer vault) private view {
        if (address(this) != address(vault)) revert InvalidVaultContext();
        if (vault.asset() != _asset) revert AssetMismatch();
    }

    /// @notice Full position value, irrespective of the withdrawal limit.
    /// @dev The fToken previews accrue the Liquidity exchange price to this block.
    function getDepositBalance(address user, IRebalancer) external view override returns (uint256) {
        uint256 shares = fToken.balanceOf(user);
        return shares == 0 ? 0 : fToken.previewRedeem(shares);
    }

    /// @notice Net supply APR in ray (1e27) at the Liquidity layer, excluding fToken rewards.
    /// @dev Ported from LiquidityCalcs.calcExchangePrices: the rate the supply exchange
    ///      price grows at, from the stored borrow rate, fee, utilization and the
    ///      interest-free ratios. Rewards (LendingRewardsRateModel) are left out, so an
    ///      active program understates the rate.
    function getDepositRate(IRebalancer) external view override returns (uint256) {
        uint256 w = liquidity.readFromStorage(keccak256(abi.encode(_asset, EXCHANGE_PRICES_SLOT)));
        return _supplyYield(w & 0xffff, (w >> 16) & 0x3fff, (w >> 30) & 0x3fff, (w >> 219) & 0x7fff, (w >> 234) & 0x7fff)
            * YIELD_TO_RAY;
    }

    /// @dev borrowRate, fee and utilization with 1e4 = 100%. A ratio is the smaller side
    ///      over the larger in 1e4, shifted left, bit 0 set when the interest-free side
    ///      is the larger one. Result: yearly supply yield with 1e12 = 100%.
    function _supplyYield(uint256 borrowRate, uint256 fee, uint256 utilization, uint256 supplyRatio, uint256 borrowRatio)
        private
        pure
        returns (uint256)
    {
        // all supply or all borrow interest-free: no supplier earns
        if (borrowRate == 0 || borrowRatio == 1 || supplyRatio == 1) return 0;
        uint256 supplyShare;
        if (supplyRatio & 1 == 1) {
            supplyShare = (RAY * 1e4) / (supplyRatio >> 1);
            supplyShare = (utilization * (RAY + supplyShare)) / 1e4;
        } else {
            supplyShare = (RAY * utilization * (1e4 + (supplyRatio >> 1))) / 1e8;
        }
        uint256 borrowShare;
        if (borrowRatio & 1 == 1) {
            borrowShare = ((borrowRatio >> 1) * RAY) / (1e4 + (borrowRatio >> 1));
        } else {
            borrowShare = RAY - (((borrowRatio >> 1) * RAY) / (1e4 + (borrowRatio >> 1)));
        }
        return borrowRate * ((1e4 * supplyShare * borrowShare) / 1e54) * (1e4 - fee);
    }

    function getSource(address, address, address) external view override returns (address) {
        return address(fToken);
    }

    function getIdentifier() external pure override returns (string memory) {
        return "Fluid_Provider";
    }
}
