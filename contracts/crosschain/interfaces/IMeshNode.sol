// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IMeshNode {
    function asset() external view returns (address);
    function balanceOf(address vault) external view returns (uint256);
    function localAssets(address vault) external view returns (uint256);

    /// @dev Only registered vaults; called atomically after the provider transfers funds.
    function depositFromVault(uint256 amount) external;

    /// @dev Pays only msg.sender. Reverts unless the full local amount is available.
    function withdrawToVault(uint256 amount) external;

    /// @dev Only the transfer's adapter may call after authenticating the remote peer.
    /// Pulls `amount` from that adapter and closes the transfer, even on a short return.
    function receiveReturn(
        bytes32 transferId,
        uint256 sourceChainId,
        bytes32 sourcePeer,
        uint256 amount
    ) external;
}
