// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICrossChainMessenger {
    function sendMessage(
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address refundAddress
    ) external payable returns (bytes32 messageId);
}
