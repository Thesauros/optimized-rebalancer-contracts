// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAssetBridge} from "./interfaces/IAssetBridge.sol";
import {IDlnSource} from "./interfaces/IDlnSource.sol";
import {ConnectorCodec} from "./libraries/ConnectorCodec.sol";

interface ITronWithdrawalReceiver {
    function receiveBridgedWithdrawal(uint256 bridgeAmount, bytes calldata payload) external;
}

contract BaseDlnAssetBridge is IAssetBridge, Ownable {
    using SafeERC20 for IERC20;

    struct ExternalCallEnvelopeV1 {
        address fallbackAddress;
        address executorAddress;
        uint160 executionFee;
        bool allowDelayedExecution;
        bool requireSuccessfulExecution;
        bytes payload;
    }

    struct UniversalHookPayload {
        address to;
        uint32 txGas;
        bytes callData;
    }

    error AddressZero();
    error AlreadyConfigured();
    error InvalidAmount();
    error InvalidDestination();
    error InvalidProtocolFee();
    error Unauthorized();

    IDlnSource public immutable dlnSource;
    IERC20 public immutable baseUsdc;
    uint32 public immutable tronChain;
    bytes32 public immutable tronUsdt;
    bytes32 public immutable tronGateway;
    uint32 public immutable hookGas;
    uint32 public immutable referralCode;

    address public connector;

    event ConnectorConfigured(address indexed connector);

    constructor(
        address owner_,
        address dlnSource_,
        address baseUsdc_,
        uint32 tronChain_,
        bytes32 tronUsdt_,
        bytes32 tronGateway_,
        uint32 hookGas_,
        uint32 referralCode_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            dlnSource_ == address(0) ||
            baseUsdc_ == address(0) ||
            tronUsdt_ == bytes32(0) ||
            tronGateway_ == bytes32(0)
        ) revert AddressZero();
        if (tronChain_ == 0 || hookGas_ == 0) revert InvalidDestination();

        dlnSource = IDlnSource(dlnSource_);
        baseUsdc = IERC20(baseUsdc_);
        tronChain = tronChain_;
        tronUsdt = tronUsdt_;
        tronGateway = tronGateway_;
        hookGas = hookGas_;
        referralCode = referralCode_;
    }

    function setConnector(address connector_) external onlyOwner {
        if (connector_ == address(0)) revert AddressZero();
        if (connector != address(0)) revert AlreadyConfigured();
        connector = connector_;
        emit ConnectorConfigured(connector_);
    }

    function bridgeAsset(
        address token,
        uint256 amount,
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address
    ) external payable returns (bytes32 orderId) {
        if (msg.sender != connector) revert Unauthorized();
        if (token != address(baseUsdc)) revert InvalidDestination();
        if (destinationChain != tronChain || receiver != tronGateway) {
            revert InvalidDestination();
        }
        if (amount == 0) revert InvalidAmount();

        (, uint256 minTronAssets, bytes32 encodedReceiver) = ConnectorCodec
            .decodeWithdrawal(payload);
        if (minTronAssets == 0 || encodedReceiver == bytes32(0)) revert InvalidAmount();

        uint256 protocolFee = dlnSource.globalFixedNativeFee();
        if (msg.value != protocolFee) revert InvalidProtocolFee();

        baseUsdc.safeTransferFrom(msg.sender, address(this), amount);
        baseUsdc.forceApprove(address(dlnSource), amount);
        orderId = _createOrder(amount, minTronAssets, payload, protocolFee);
        baseUsdc.forceApprove(address(dlnSource), 0);
    }

    function _createOrder(
        uint256 amount,
        uint256 minTronAssets,
        bytes calldata payload,
        uint256 protocolFee
    ) private returns (bytes32 orderId) {
        IDlnSource.OrderCreation memory order = IDlnSource.OrderCreation({
            giveTokenAddress: address(baseUsdc),
            giveAmount: amount,
            takeTokenAddress: _bytes32ToAddressBytes(tronUsdt),
            takeAmount: minTronAssets,
            takeChainId: tronChain,
            receiverDst: _bytes32ToAddressBytes(tronGateway),
            givePatchAuthoritySrc: connector,
            orderAuthorityAddressDst: _bytes32ToAddressBytes(tronGateway),
            allowedTakerDst: bytes(""),
            externalCall: _buildExternalCall(minTronAssets, payload),
            allowedCancelBeneficiarySrc: abi.encodePacked(connector)
        });

        orderId = dlnSource.createOrder{value: protocolFee}(
            order,
            bytes(""),
            referralCode,
            bytes("")
        );
    }

    function _buildExternalCall(
        uint256 minTronAssets,
        bytes calldata payload
    ) private view returns (bytes memory) {
        address gateway = _bytes32ToAddress(tronGateway);
        bytes memory hookCallData = abi.encodeCall(
            ITronWithdrawalReceiver.receiveBridgedWithdrawal,
            (minTronAssets, payload)
        );
        bytes memory hookPayload = abi.encode(
            UniversalHookPayload({to: gateway, txGas: hookGas, callData: hookCallData})
        );
        return abi.encode(
            ExternalCallEnvelopeV1({
                fallbackAddress: gateway,
                executorAddress: address(0),
                executionFee: 0,
                allowDelayedExecution: false,
                requireSuccessfulExecution: true,
                payload: hookPayload
            })
        );
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
