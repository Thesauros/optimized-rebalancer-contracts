// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Transport boundary. Implementations must authenticate remote messages.
interface IMeshBridgeAdapter {
    /// @dev Pull exactly `amount` from msg.sender and return the principal committed
    /// to the destination. Native fees are supplied by the executor, not the vault.
    /// `transferId` must be carried through the remote custody/return cycle.
    function send(
        bytes32 transferId,
        address asset,
        uint256 amount,
        uint256 destinationChainId,
        bytes32 destinationPeer,
        uint256 minAmountOut
    ) external payable returns (uint256 amountOut);
}
