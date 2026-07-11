// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ConnectorCodec {
    uint8 internal constant VERSION = 1;

    enum MessageType {
        Invalid,
        Deposit,
        DepositAck,
        Redeem,
        Withdrawal
    }

    error InvalidMessage();

    function encodeDeposit(
        bytes32 requestId,
        uint256 minShares,
        uint64 deadline,
        bytes32 receiver
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                VERSION,
                uint8(MessageType.Deposit),
                requestId,
                minShares,
                deadline,
                receiver
            );
    }

    function decodeDeposit(
        bytes calldata payload
    )
        internal
        pure
        returns (
            bytes32 requestId,
            uint256 minShares,
            uint64 deadline,
            bytes32 receiver
        )
    {
        uint8 version;
        uint8 rawType;
        (version, rawType, requestId, minShares, deadline, receiver) = abi
            .decode(payload, (uint8, uint8, bytes32, uint256, uint64, bytes32));
        _validate(version, rawType, MessageType.Deposit);
    }

    function encodeDepositAck(
        bytes32 requestId,
        uint256 shares,
        uint8 shareDecimals
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                VERSION,
                uint8(MessageType.DepositAck),
                requestId,
                shares,
                shareDecimals
            );
    }

    function decodeDepositAck(
        bytes calldata payload
    ) internal pure returns (bytes32 requestId, uint256 shares, uint8 shareDecimals) {
        uint8 version;
        uint8 rawType;
        (version, rawType, requestId, shares, shareDecimals) = abi.decode(
            payload,
            (uint8, uint8, bytes32, uint256, uint8)
        );
        _validate(version, rawType, MessageType.DepositAck);
    }

    function encodeRedeem(
        bytes32 requestId,
        uint256 shares,
        uint256 minVaultAssets,
        uint256 minTronAssets,
        bytes32 receiver
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                VERSION,
                uint8(MessageType.Redeem),
                requestId,
                shares,
                minVaultAssets,
                minTronAssets,
                receiver
            );
    }

    function decodeRedeem(
        bytes calldata payload
    )
        internal
        pure
        returns (
            bytes32 requestId,
            uint256 shares,
            uint256 minVaultAssets,
            uint256 minTronAssets,
            bytes32 receiver
        )
    {
        uint8 version;
        uint8 rawType;
        (
            version,
            rawType,
            requestId,
            shares,
            minVaultAssets,
            minTronAssets,
            receiver
        ) = abi.decode(
            payload,
            (uint8, uint8, bytes32, uint256, uint256, uint256, bytes32)
        );
        _validate(version, rawType, MessageType.Redeem);
    }

    function encodeWithdrawal(
        bytes32 requestId,
        uint256 minTronAssets,
        bytes32 receiver
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                VERSION,
                uint8(MessageType.Withdrawal),
                requestId,
                minTronAssets,
                receiver
            );
    }

    function decodeWithdrawal(
        bytes calldata payload
    )
        internal
        pure
        returns (
            bytes32 requestId,
            uint256 minTronAssets,
            bytes32 receiver
        )
    {
        uint8 version;
        uint8 rawType;
        (version, rawType, requestId, minTronAssets, receiver) = abi.decode(
            payload,
            (uint8, uint8, bytes32, uint256, bytes32)
        );
        _validate(version, rawType, MessageType.Withdrawal);
    }

    function messageType(bytes calldata payload) internal pure returns (MessageType) {
        (uint8 version, uint8 rawType) = abi.decode(payload, (uint8, uint8));
        if (version != VERSION || rawType > uint8(MessageType.Withdrawal)) {
            revert InvalidMessage();
        }
        return MessageType(rawType);
    }

    function _validate(
        uint8 version,
        uint8 actualType,
        MessageType expectedType
    ) private pure {
        if (version != VERSION || actualType != uint8(expectedType)) {
            revert InvalidMessage();
        }
    }
}
