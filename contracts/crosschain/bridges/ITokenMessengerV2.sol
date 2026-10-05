// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Circle CCTP V2 TokenMessenger interface (burn side).
interface ITokenMessengerV2 {
    /// @dev CCTP V2 depositForBurn with destination caller restriction, max fee, and finality threshold.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external returns (uint64 nonce);

    /// @dev CCTP V1 compatible depositForBurn (no caller restriction, no fee).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);

    event DepositForBurn(
        uint64 indexed nonce,
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller
    );
}

/// @notice Circle CCTP V2 MessageTransmitter interface (receive side).
interface IMessageTransmitterV2 {
    /// @dev Submit attestation to mint tokens on destination chain.
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);

    function localDomain() external view returns (uint32);

    event MessageReceived(
        address indexed caller,
        uint32 indexed sourceDomain,
        uint64 indexed nonce,
        bytes32 sender,
        bytes messageBody
    );
}
