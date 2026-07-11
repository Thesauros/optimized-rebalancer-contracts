// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAssetBridge {
    function bridgeAsset(
        address token,
        uint256 amount,
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address refundAddress
    ) external payable returns (bytes32 transferId);
}
