// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICustodianProvider} from "../../contracts/crosschain/interfaces/ICustodianProvider.sol";

/// @notice Test-only custodian provider that simulates yield deployment.
/// @dev Receives tokens on deposit, returns them on withdraw. Optionally
///      simulates yield by returning more than deposited.
contract MockCustodianProvider is ICustodianProvider {
    using SafeERC20 for IERC20;

    address public immutable asset;
    uint256 public totalDeposited;
    uint256 public yieldBps;

    constructor(address asset_) {
        asset = asset_;
    }

    function setYieldBps(uint256 bps) external {
        yieldBps = bps;
    }

    /// @notice Accept tokens (already transferred by custodian) and track deposit.
    function deposit(uint256 amount) external returns (bool) {
        totalDeposited += amount;
        return true;
    }

    /// @notice Return tokens to custodian. If yield is configured, mint extra.
    function withdraw(uint256 amount) external returns (bool) {
        uint256 yieldAmount = (amount * yieldBps) / 10_000;
        uint256 totalReturn = amount + yieldAmount;

        // If we don't have enough, return what we can
        uint256 available = IERC20(asset).balanceOf(address(this));
        if (totalReturn > available) {
            totalReturn = available;
        }

        if (totalReturn > 0) {
            IERC20(asset).safeTransfer(msg.sender, totalReturn);
        }

        totalDeposited = totalDeposited > amount ? totalDeposited - amount : 0;
        return true;
    }

    /// @notice Simulate yield by minting tokens to this contract.
    function simulateYield(uint256 amount) external {
        IERC20(asset).transfer(address(this), amount);
    }
}
