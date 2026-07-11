// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {IAssetBridge} from "./interfaces/IAssetBridge.sol";
import {ICrossChainMessenger} from "./interfaces/ICrossChainMessenger.sol";
import {ConnectorCodec} from "./libraries/ConnectorCodec.sol";

contract EvmTronConnector is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum DepositState {
        None,
        Invested
    }

    enum RedeemState {
        None,
        Requested,
        BridgeSent
    }

    struct DepositRecord {
        uint256 assets;
        uint256 shares;
        uint256 minShares;
        uint64 deadline;
        bytes32 tronReceiver;
        DepositState state;
        bytes32 lastAckMessageId;
    }

    struct RedeemRecord {
        uint256 shares;
        uint256 minVaultAssets;
        uint256 minTronAssets;
        uint256 assetsRedeemed;
        bytes32 tronReceiver;
        RedeemState state;
        bytes32 bridgeTransferId;
    }

    error AddressZero();
    error InvalidAsset();
    error InvalidChain();
    error InvalidAmount();
    error InvalidMessageOrigin();
    error InvalidRequest();
    error InvalidState();
    error DeadlineExpired();
    error InsufficientBacking();
    error SlippageExceeded();
    error BridgeDidNotPullAssets();
    error BackingTokenRescueForbidden();

    IRebalancer public immutable vault;
    IERC20 public immutable asset;
    IERC20 public immutable vaultShare;
    address public immutable depositExecutor;
    IAssetBridge public immutable assetBridge;
    ICrossChainMessenger public immutable messenger;
    uint32 public immutable tronChain;
    bytes32 public immutable tronGateway;

    uint256 public allocatedShares;
    uint256 public reservedRedeemShares;
    mapping(bytes32 requestId => DepositRecord) public deposits;
    mapping(bytes32 requestId => RedeemRecord) public redeems;

    event DepositInvested(
        bytes32 indexed requestId,
        uint256 assets,
        uint256 shares,
        bytes32 indexed tronReceiver
    );
    event DepositAckSent(bytes32 indexed requestId, bytes32 indexed messageId, uint256 shares);
    event RedeemReceived(
        bytes32 indexed requestId,
        uint256 shares,
        uint256 minTronAssets,
        bytes32 indexed tronReceiver
    );
    event RedeemBridged(
        bytes32 indexed requestId,
        uint256 shares,
        uint256 assets,
        bytes32 indexed bridgeTransferId
    );
    event RedeemBridgeRetried(bytes32 indexed requestId, bytes32 indexed bridgeTransferId);

    constructor(
        address owner_,
        address vault_,
        address depositExecutor_,
        address assetBridge_,
        address messenger_,
        uint32 tronChain_,
        bytes32 tronGateway_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            vault_ == address(0) ||
            depositExecutor_ == address(0) ||
            assetBridge_ == address(0) ||
            messenger_ == address(0) ||
            tronGateway_ == bytes32(0)
        ) revert AddressZero();
        if (tronChain_ == 0) revert InvalidChain();

        IRebalancer vaultContract = IRebalancer(vault_);
        address assetAddress = vaultContract.asset();
        if (assetAddress == address(0)) revert InvalidAsset();
        uint8 assetDecimals = IERC20Metadata(assetAddress).decimals();
        if (assetDecimals != 6 || assetDecimals != IERC20Metadata(vault_).decimals()) {
            revert InvalidAsset();
        }

        vault = vaultContract;
        asset = IERC20(assetAddress);
        vaultShare = IERC20(vault_);
        depositExecutor = depositExecutor_;
        assetBridge = IAssetBridge(assetBridge_);
        messenger = ICrossChainMessenger(messenger_);
        tronChain = tronChain_;
        tronGateway = tronGateway_;
    }

    function receiveBridgedDeposit(
        uint256 bridgeAmount,
        bytes calldata payload
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (msg.sender != depositExecutor) revert InvalidMessageOrigin();

        (
            bytes32 requestId,
            uint256 minShares,
            uint64 deadline,
            bytes32 tronReceiver
        ) = ConnectorCodec.decodeDeposit(payload);
        if (bridgeAmount == 0 || minShares == 0) revert InvalidAmount();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (tronReceiver == bytes32(0)) revert AddressZero();
        if (deposits[requestId].state != DepositState.None) revert InvalidState();

        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), bridgeAmount);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidAmount();

        asset.forceApprove(address(vault), received);
        shares = vault.deposit(received, address(this));
        asset.forceApprove(address(vault), 0);
        if (shares < minShares || shares == 0) revert SlippageExceeded();

        deposits[requestId] = DepositRecord({
            assets: received,
            shares: shares,
            minShares: minShares,
            deadline: deadline,
            tronReceiver: tronReceiver,
            state: DepositState.Invested,
            lastAckMessageId: bytes32(0)
        });
        allocatedShares += shares;

        emit DepositInvested(requestId, received, shares, tronReceiver);
    }

    function sendDepositAck(
        bytes32 requestId
    ) external payable nonReentrant returns (bytes32 messageId) {
        DepositRecord storage request = deposits[requestId];
        if (request.state != DepositState.Invested) revert InvalidState();

        messageId = messenger.sendMessage{value: msg.value}(
            tronChain,
            tronGateway,
            ConnectorCodec.encodeDepositAck(
                requestId,
                request.shares,
                IERC20Metadata(address(vaultShare)).decimals()
            ),
            msg.sender
        );
        request.lastAckMessageId = messageId;

        emit DepositAckSent(requestId, messageId, request.shares);
    }

    function receiveMessage(
        uint32 sourceChain,
        bytes32 sourceSender,
        bytes calldata payload
    ) external nonReentrant whenNotPaused {
        if (
            msg.sender != address(messenger) ||
            sourceChain != tronChain ||
            sourceSender != tronGateway
        ) revert InvalidMessageOrigin();
        if (ConnectorCodec.messageType(payload) != ConnectorCodec.MessageType.Redeem) {
            revert InvalidRequest();
        }

        (
            bytes32 requestId,
            uint256 shares,
            uint256 minVaultAssets,
            uint256 minTronAssets,
            bytes32 tronReceiver
        ) = ConnectorCodec.decodeRedeem(payload);
        if (shares == 0 || minVaultAssets == 0 || minTronAssets == 0) {
            revert InvalidAmount();
        }
        if (tronReceiver == bytes32(0)) revert AddressZero();

        RedeemRecord storage existing = redeems[requestId];
        if (existing.state != RedeemState.None) {
            if (
                existing.shares != shares ||
                existing.minVaultAssets != minVaultAssets ||
                existing.minTronAssets != minTronAssets ||
                existing.tronReceiver != tronReceiver
            ) revert InvalidRequest();
            return;
        }
        if (shares > allocatedShares - reservedRedeemShares) {
            revert InsufficientBacking();
        }

        redeems[requestId] = RedeemRecord({
            shares: shares,
            minVaultAssets: minVaultAssets,
            minTronAssets: minTronAssets,
            assetsRedeemed: 0,
            tronReceiver: tronReceiver,
            state: RedeemState.Requested,
            bridgeTransferId: bytes32(0)
        });
        reservedRedeemShares += shares;

        emit RedeemReceived(requestId, shares, minTronAssets, tronReceiver);
    }

    function processRedeem(
        bytes32 requestId
    ) external payable nonReentrant returns (bytes32 transferId) {
        RedeemRecord storage request = redeems[requestId];
        if (request.state != RedeemState.Requested) revert InvalidState();
        uint256 balanceBefore = asset.balanceOf(address(this));
        uint256 reportedAssets = vault.redeem(
            request.shares,
            address(this),
            address(this)
        );
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;
        if (reportedAssets != received || received < request.minVaultAssets) {
            revert SlippageExceeded();
        }

        request.assetsRedeemed = received;
        request.state = RedeemState.BridgeSent;
        allocatedShares -= request.shares;
        reservedRedeemShares -= request.shares;

        asset.forceApprove(address(assetBridge), received);
        transferId = assetBridge.bridgeAsset{value: msg.value}(
            address(asset),
            received,
            tronChain,
            tronGateway,
            ConnectorCodec.encodeWithdrawal(
                requestId,
                request.minTronAssets,
                request.tronReceiver
            ),
            msg.sender
        );
        asset.forceApprove(address(assetBridge), 0);

        if (asset.balanceOf(address(this)) != balanceBefore) {
            revert BridgeDidNotPullAssets();
        }
        request.bridgeTransferId = transferId;

        emit RedeemBridged(requestId, request.shares, received, transferId);
    }

    function retryRedeemBridge(
        bytes32 requestId
    ) external payable onlyOwner nonReentrant returns (bytes32 transferId) {
        RedeemRecord storage request = redeems[requestId];
        if (request.state != RedeemState.BridgeSent || request.assetsRedeemed == 0) {
            revert InvalidState();
        }

        uint256 amount = request.assetsRedeemed;
        uint256 balanceBefore = asset.balanceOf(address(this));
        if (balanceBefore < amount) revert InsufficientBacking();

        asset.forceApprove(address(assetBridge), amount);
        transferId = assetBridge.bridgeAsset{value: msg.value}(
            address(asset),
            amount,
            tronChain,
            tronGateway,
            ConnectorCodec.encodeWithdrawal(
                requestId,
                request.minTronAssets,
                request.tronReceiver
            ),
            msg.sender
        );
        asset.forceApprove(address(assetBridge), 0);

        if (asset.balanceOf(address(this)) != balanceBefore - amount) {
            revert BridgeDidNotPullAssets();
        }
        request.bridgeTransferId = transferId;

        emit RedeemBridgeRetried(requestId, transferId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueToken(address token, address receiver, uint256 amount) external onlyOwner {
        if (token == address(asset) || token == address(vaultShare)) {
            revert BackingTokenRescueForbidden();
        }
        if (receiver == address(0)) revert AddressZero();
        IERC20(token).safeTransfer(receiver, amount);
    }
}
