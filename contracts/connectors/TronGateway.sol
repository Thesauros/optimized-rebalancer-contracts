// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAssetBridge} from "./interfaces/IAssetBridge.sol";
import {ICrossChainMessenger} from "./interfaces/ICrossChainMessenger.sol";
import {ConnectorCodec} from "./libraries/ConnectorCodec.sol";
import {TronTUSDT} from "./TronTUSDT.sol";

contract TronGateway is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum DepositState {
        None,
        BridgeSent,
        Minted,
        Refunded
    }

    enum RedeemState {
        None,
        RequestSent,
        Paid
    }

    struct DepositRequest {
        address account;
        address receiver;
        uint256 assets;
        uint256 shares;
        uint256 minShares;
        uint64 deadline;
        DepositState state;
        bytes32 bridgeTransferId;
    }

    struct RedeemRequest {
        address account;
        address receiver;
        uint256 shares;
        uint256 minVaultAssets;
        uint256 minTronAssets;
        uint256 assetsPaid;
        RedeemState state;
        bytes32 messageId;
    }

    error AddressZero();
    error InvalidChain();
    error InvalidDecimals();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidMessageOrigin();
    error InvalidRequest();
    error InvalidState();
    error SlippageExceeded();
    error BridgeDidNotPullAssets();
    error BackingTokenRescueForbidden();

    IERC20 public immutable usdt;
    TronTUSDT public immutable tUSDT;
    address public immutable payoutExecutor;
    IAssetBridge public immutable assetBridge;
    ICrossChainMessenger public immutable messenger;
    uint32 public immutable evmChain;
    bytes32 public immutable evmConnector;

    uint256 public nextNonce;
    mapping(bytes32 requestId => DepositRequest) public deposits;
    mapping(bytes32 requestId => RedeemRequest) public redeems;

    event DepositRequested(
        bytes32 indexed requestId,
        address indexed account,
        address indexed receiver,
        uint256 assets,
        uint256 minShares,
        bytes32 bridgeTransferId
    );
    event DepositFinalized(bytes32 indexed requestId, address indexed receiver, uint256 shares);
    event DepositRefunded(bytes32 indexed requestId, address indexed account, uint256 assets);
    event RedeemRequested(
        bytes32 indexed requestId,
        address indexed account,
        address indexed receiver,
        uint256 shares,
        uint256 minTronAssets,
        bytes32 messageId
    );
    event RedeemFinalized(
        bytes32 indexed requestId,
        address indexed receiver,
        uint256 shares,
        uint256 assets
    );

    constructor(
        address owner_,
        address usdt_,
        address payoutExecutor_,
        address assetBridge_,
        address messenger_,
        uint32 evmChain_,
        bytes32 evmConnector_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            usdt_ == address(0) ||
            payoutExecutor_ == address(0) ||
            assetBridge_ == address(0) ||
            messenger_ == address(0) ||
            evmConnector_ == bytes32(0)
        ) revert AddressZero();
        if (evmChain_ == 0) revert InvalidChain();
        if (IERC20Metadata(usdt_).decimals() != 6) revert InvalidDecimals();

        usdt = IERC20(usdt_);
        payoutExecutor = payoutExecutor_;
        assetBridge = IAssetBridge(assetBridge_);
        messenger = ICrossChainMessenger(messenger_);
        evmChain = evmChain_;
        evmConnector = evmConnector_;
        tUSDT = new TronTUSDT(address(this), 6);
    }

    function requestDeposit(
        uint256 assets,
        uint256 minShares,
        uint64 deadline,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (bytes32 requestId) {
        if (assets == 0 || minShares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert AddressZero();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        uint256 balanceBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = usdt.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidAmount();

        requestId = _nextRequestId(msg.sender, ConnectorCodec.MessageType.Deposit);
        DepositRequest storage request = deposits[requestId];
        request.account = msg.sender;
        request.receiver = receiver;
        request.assets = received;
        request.minShares = minShares;
        request.deadline = deadline;
        request.state = DepositState.BridgeSent;

        bytes memory payload = ConnectorCodec.encodeDeposit(
            requestId,
            minShares,
            deadline,
            _addressToBytes32(receiver)
        );

        usdt.forceApprove(address(assetBridge), received);
        request.bridgeTransferId = assetBridge.bridgeAsset{value: msg.value}(
            address(usdt),
            received,
            evmChain,
            evmConnector,
            payload,
            msg.sender
        );
        usdt.forceApprove(address(assetBridge), 0);

        if (usdt.balanceOf(address(this)) != balanceBefore) {
            revert BridgeDidNotPullAssets();
        }

        emit DepositRequested(
            requestId,
            msg.sender,
            receiver,
            received,
            minShares,
            request.bridgeTransferId
        );
    }

    function requestRedeem(
        uint256 shares,
        uint256 minVaultAssets,
        uint256 minTronAssets,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (bytes32 requestId) {
        if (shares == 0 || minVaultAssets == 0 || minTronAssets == 0) {
            revert InvalidAmount();
        }
        if (receiver == address(0)) revert AddressZero();

        IERC20(address(tUSDT)).safeTransferFrom(msg.sender, address(this), shares);

        requestId = _nextRequestId(msg.sender, ConnectorCodec.MessageType.Redeem);
        RedeemRequest storage request = redeems[requestId];
        request.account = msg.sender;
        request.receiver = receiver;
        request.shares = shares;
        request.minVaultAssets = minVaultAssets;
        request.minTronAssets = minTronAssets;
        request.state = RedeemState.RequestSent;

        request.messageId = messenger.sendMessage{value: msg.value}(
            evmChain,
            evmConnector,
            ConnectorCodec.encodeRedeem(
                requestId,
                shares,
                minVaultAssets,
                minTronAssets,
                _addressToBytes32(receiver)
            ),
            msg.sender
        );

        emit RedeemRequested(
            requestId,
            msg.sender,
            receiver,
            shares,
            minTronAssets,
            request.messageId
        );
    }

    function receiveMessage(
        uint32 sourceChain,
        bytes32 sourceSender,
        bytes calldata payload
    ) external nonReentrant {
        if (
            msg.sender != address(messenger) ||
            sourceChain != evmChain ||
            sourceSender != evmConnector
        ) revert InvalidMessageOrigin();
        if (ConnectorCodec.messageType(payload) != ConnectorCodec.MessageType.DepositAck) {
            revert InvalidRequest();
        }

        (
            bytes32 requestId,
            uint256 shares,
            uint8 shareDecimals
        ) = ConnectorCodec.decodeDepositAck(payload);
        DepositRequest storage request = deposits[requestId];
        if (request.state == DepositState.Minted) {
            if (request.shares != shares) revert InvalidRequest();
            return;
        }
        if (request.state != DepositState.BridgeSent) revert InvalidState();
        if (shareDecimals != tUSDT.decimals()) revert InvalidRequest();
        if (shares < request.minShares || shares == 0) revert SlippageExceeded();

        request.shares = shares;
        request.state = DepositState.Minted;
        tUSDT.mint(request.receiver, shares);

        emit DepositFinalized(requestId, request.receiver, shares);
    }

    function receiveBridgedWithdrawal(
        uint256 bridgeAmount,
        bytes calldata payload
    ) external nonReentrant {
        if (msg.sender != payoutExecutor) revert InvalidMessageOrigin();

        (
            bytes32 requestId,
            uint256 minTronAssets,
            bytes32 encodedReceiver
        ) = ConnectorCodec.decodeWithdrawal(payload);
        RedeemRequest storage request = redeems[requestId];

        if (request.state != RedeemState.RequestSent) revert InvalidState();
        if (
            minTronAssets != request.minTronAssets ||
            encodedReceiver != _addressToBytes32(request.receiver)
        ) revert InvalidRequest();

        uint256 balanceBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), bridgeAmount);
        uint256 received = usdt.balanceOf(address(this)) - balanceBefore;
        if (received < request.minTronAssets) revert SlippageExceeded();

        request.assetsPaid = received;
        request.state = RedeemState.Paid;
        tUSDT.burn(request.shares);
        usdt.safeTransfer(request.receiver, received);

        emit RedeemFinalized(requestId, request.receiver, request.shares, received);
    }

    function receiveBridgedDepositRefund(
        uint256 bridgeAmount,
        bytes calldata payload
    ) external nonReentrant {
        if (msg.sender != payoutExecutor) revert InvalidMessageOrigin();

        (
            bytes32 requestId,
            uint256 minShares,
            uint64 deadline,
            bytes32 encodedReceiver
        ) = ConnectorCodec.decodeDeposit(payload);
        DepositRequest storage request = deposits[requestId];

        if (request.state != DepositState.BridgeSent) revert InvalidState();
        if (
            minShares != request.minShares ||
            deadline != request.deadline ||
            encodedReceiver != _addressToBytes32(request.receiver)
        ) revert InvalidRequest();

        uint256 balanceBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), bridgeAmount);
        uint256 received = usdt.balanceOf(address(this)) - balanceBefore;
        if (received == 0 || received > request.assets) revert InvalidAmount();

        request.state = DepositState.Refunded;
        usdt.safeTransfer(request.account, received);

        emit DepositRefunded(requestId, request.account, received);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueToken(address token, address receiver, uint256 amount) external onlyOwner {
        if (token == address(usdt) || token == address(tUSDT)) {
            revert BackingTokenRescueForbidden();
        }
        if (receiver == address(0)) revert AddressZero();
        IERC20(token).safeTransfer(receiver, amount);
    }

    function _nextRequestId(
        address account,
        ConnectorCodec.MessageType requestType
    ) private returns (bytes32) {
        uint256 nonce = ++nextNonce;
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    account,
                    nonce,
                    uint8(requestType)
                )
            );
    }

    function _addressToBytes32(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
