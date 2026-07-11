// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICrossChainMessenger} from "./interfaces/ICrossChainMessenger.sol";
import {IDeBridgeGate} from "./interfaces/IDeBridgeGate.sol";
import {IDeBridgeCallProxy} from "./interfaces/IDeBridgeCallProxy.sol";

interface IConnectorMessageReceiver {
    function receiveMessage(
        uint32 sourceChain,
        bytes32 sourceSender,
        bytes calldata payload
    ) external;
}

contract DeBridgeMessengerAdapter is ICrossChainMessenger {
    error AddressZero();
    error InvalidDestination();
    error InvalidMessageOrigin();
    error InvalidProtocolFee();

    IDeBridgeGate public immutable deBridgeGate;
    IDeBridgeCallProxy public immutable callProxy;
    uint32 public immutable remoteChain;
    bytes32 public immutable remoteAdapter;

    constructor(address gate_, uint32 remoteChain_, bytes32 remoteAdapter_) {
        if (gate_ == address(0) || remoteAdapter_ == bytes32(0)) revert AddressZero();
        if (remoteChain_ == 0) revert InvalidDestination();

        IDeBridgeGate gate = IDeBridgeGate(gate_);
        address proxy = gate.callProxy();
        if (proxy == address(0)) revert AddressZero();

        deBridgeGate = gate;
        callProxy = IDeBridgeCallProxy(proxy);
        remoteChain = remoteChain_;
        remoteAdapter = remoteAdapter_;
    }

    function sendMessage(
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address
    ) external payable returns (bytes32 messageId) {
        if (destinationChain != remoteChain || receiver == bytes32(0)) {
            revert InvalidDestination();
        }
        if (msg.value < deBridgeGate.globalFixedNativeFee()) revert InvalidProtocolFee();

        bytes memory callData = abi.encodeCall(
            this.receiveMessage,
            (_addressToBytes32(msg.sender), receiver, payload)
        );
        messageId = deBridgeGate.sendMessage{value: msg.value}(
            destinationChain,
            _bytes32ToAddressBytes(remoteAdapter),
            callData
        );
    }

    function receiveMessage(
        bytes32 sourceApplication,
        bytes32 destinationApplication,
        bytes calldata payload
    ) external {
        if (msg.sender != address(callProxy)) revert InvalidMessageOrigin();
        if (callProxy.submissionChainIdFrom() != remoteChain) {
            revert InvalidMessageOrigin();
        }
        if (
            keccak256(callProxy.submissionNativeSender()) !=
            keccak256(_bytes32ToAddressBytes(remoteAdapter))
        ) revert InvalidMessageOrigin();

        address destination = _bytes32ToAddress(destinationApplication);
        IConnectorMessageReceiver(destination).receiveMessage(
            remoteChain,
            sourceApplication,
            payload
        );
    }

    function _addressToBytes32(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _bytes32ToAddress(bytes32 value) private pure returns (address result) {
        if (uint256(value) >> 160 != 0) revert InvalidDestination();
        result = address(uint160(uint256(value)));
        if (result == address(0)) revert AddressZero();
    }

    function _bytes32ToAddressBytes(bytes32 value) private pure returns (bytes memory) {
        return abi.encodePacked(_bytes32ToAddress(value));
    }
}

