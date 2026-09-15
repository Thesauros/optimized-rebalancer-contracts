// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Simplified provider interface for MeshCustodian yield deployment.
/// @dev Unlike the vault's IProvider (which runs via delegatecall inside a
/// Rebalancer and receives a vault argument), custodian providers run via
/// delegatecall inside the custodian itself. No vault context is needed.
interface ICustodianProvider {
    /// @notice Pull `amount` from the caller (custodian) and deploy into yield.
    function deposit(uint256 amount) external returns (bool success);

    /// @notice Withdraw `amount` from yield and send to the caller (custodian).
    function withdraw(uint256 amount) external returns (bool success);
}
