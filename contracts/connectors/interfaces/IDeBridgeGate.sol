// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeBridgeGate {
    function callProxy() external view returns (address);

    function globalFixedNativeFee() external view returns (uint256);

    function sendMessage(
        uint256 destinationChain,
        bytes calldata target,
        bytes calldata callData
    ) external payable returns (bytes32 submissionId);
}

