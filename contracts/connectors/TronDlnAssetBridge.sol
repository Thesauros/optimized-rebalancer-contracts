// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAssetBridge} from "./interfaces/IAssetBridge.sol";
import {IDlnSource} from "./interfaces/IDlnSource.sol";
import {ConnectorCodec} from "./libraries/ConnectorCodec.sol";

interface IBaseDepositReceiver {
    function receiveBridgedDeposit(
        uint256 bridgeAmount,
        bytes calldata payload
    ) external returns (uint256 shares);
}

contract TronDlnAssetBridge is IAssetBridge, Ownable {
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
    IERC20 public immutable tronUsdt;
    uint32 public immutable baseChain;
    bytes32 public immutable baseUsdc;
    uint32 public immutable hookGas;
    uint32 public immutable referralCode;

    address public connector;

    event ConnectorConfigured(address indexed connector);

    constructor(
        address owner_,
        address dlnSource_,
        address tronUsdt_,
        uint32 baseChain_,
        bytes32 baseUsdc_,
        uint32 hookGas_,
        uint32 referralCode_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            dlnSource_ == address(0) ||
            tronUsdt_ == address(0) ||
            baseUsdc_ == bytes32(0)
        ) revert AddressZero();
        if (baseChain_ == 0 || hookGas_ == 0) revert InvalidDestination();

        dlnSource = IDlnSource(dlnSource_);
        tronUsdt = IERC20(tronUsdt_);
        baseChain = baseChain_;
        baseUsdc = baseUsdc_;
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
        if (token != address(tronUsdt)) revert InvalidDestination();
        if (destinationChain != baseChain || receiver == bytes32(0)) {
            revert InvalidDestination();
        }
        if (amount == 0) revert InvalidAmount();

        (, uint256 minBaseAssets, uint256 minShares, , ) = ConnectorCodec
            .decodeDeposit(payload);
        if (minBaseAssets == 0 || minShares == 0) revert InvalidAmount();

        uint256 protocolFee = dlnSource.globalFixedNativeFee();
        if (msg.value != protocolFee) revert InvalidProtocolFee();

        tronUsdt.safeTransferFrom(msg.sender, address(this), amount);
        tronUsdt.forceApprove(address(dlnSource), amount);
        orderId = dlnSource.createOrder{value: protocolFee}(
            _buildOrder(amount, minBaseAssets, receiver, payload),
            bytes(""),
            referralCode,
            bytes("")
        );
        tronUsdt.forceApprove(address(dlnSource), 0);
    }

    function _buildOrder(
        uint256 amount,
        uint256 minBaseAssets,
        bytes32 receiver,
        bytes calldata payload
    ) private view returns (IDlnSource.OrderCreation memory) {
        address baseConnector = _bytes32ToAddress(receiver);
        return
            IDlnSource.OrderCreation({
                giveTokenAddress: address(tronUsdt),
                giveAmount: amount,
                takeTokenAddress: _bytes32ToAddressBytes(baseUsdc),
                takeAmount: minBaseAssets,
                takeChainId: baseChain,
                receiverDst: abi.encodePacked(baseConnector),
                givePatchAuthoritySrc: connector,
                orderAuthorityAddressDst: abi.encodePacked(baseConnector),
                allowedTakerDst: bytes(""),
                externalCall: _buildExternalCall(
                    baseConnector,
                    minBaseAssets,
                    payload
                ),
                allowedCancelBeneficiarySrc: abi.encodePacked(connector)
            });
    }

    function _buildExternalCall(
        address baseConnector,
        uint256 minBaseAssets,
        bytes calldata payload
    ) private view returns (bytes memory) {
        bytes memory hookCallData = abi.encodeCall(
            IBaseDepositReceiver.receiveBridgedDeposit,
            (minBaseAssets, payload)
        );
        bytes memory hookPayload = abi.encode(
            UniversalHookPayload({
                to: baseConnector,
                txGas: hookGas,
                callData: hookCallData
            })
        );
        return
            abi.encode(
                ExternalCallEnvelopeV1({
                    fallbackAddress: baseConnector,
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
