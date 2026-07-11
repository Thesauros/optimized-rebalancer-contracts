// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeBridgeCallProxy {
    function submissionChainIdFrom() external view returns (uint256);

    function submissionNativeSender() external view returns (bytes memory);
}

