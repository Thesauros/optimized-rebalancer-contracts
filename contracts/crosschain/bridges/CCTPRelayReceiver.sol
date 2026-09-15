// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMessageTransmitterV2} from "./ITokenMessengerV2.sol";
import {IMeshNode} from "../interfaces/IMeshNode.sol";
import {MeshCustodian} from "../MeshCustodian.sol";

/// @title CCTPRelayReceiver
/// @notice Receives minted USDC from Circle CCTP and delivers to MeshNode or MeshCustodian.
///         Deployed on each chain as the `mintRecipient` for CCTP transfers.
///
///         Two modes (set at deployment, immutable):
///           MODE_CUSTODIAN (0): calls MeshCustodian.onBridgeIn (destination chain)
///           MODE_NODE (1): calls MeshNode.receiveReturn (source chain, return path)
///
///         Only the authorized keeper can call deliver(). The keeper:
///           1. Polls Circle's attestation API for the burn message
///           2. Calls deliver(message, attestation, transferId, srcChainId, srcPeer)
///           3. Relay submits attestation to MessageTransmitter (mints USDC to relay)
///           4. Relay approves target and calls onBridgeIn / receiveReturn
contract CCTPRelayReceiver {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error Unauthorized();
    error InvalidConfiguration();
    error ZeroAmount();
    error DeliveryFailed();

    // ============ Constants ============
    uint8 public constant MODE_CUSTODIAN = 0;
    uint8 public constant MODE_NODE = 1;

    // ============ Immutables ============
    address public immutable governance;
    address public immutable messageTransmitter;
    address public immutable asset; // USDC
    address public immutable target; // MeshNode or MeshCustodian
    uint8 public immutable mode; // MODE_CUSTODIAN or MODE_NODE

    // ============ Storage ============
    address public keeper;

    event Delivered(
        bytes32 indexed transferId,
        address target,
        uint256 amount,
        uint8 mode
    );

    event KeeperUpdated(address oldKeeper, address newKeeper);

    constructor(
        address governance_,
        address messageTransmitter_,
        address asset_,
        address target_,
        uint8 mode_,
        address keeper_
    ) {
        if (governance_ == address(0) || messageTransmitter_.code.length == 0) revert InvalidConfiguration();
        if (asset_.code.length == 0 || target_.code.length == 0) revert InvalidConfiguration();
        if (mode_ > MODE_NODE) revert InvalidConfiguration();
        if (keeper_ == address(0)) revert InvalidConfiguration();

        governance = governance_;
        messageTransmitter = messageTransmitter_;
        asset = asset_;
        target = target_;
        mode = mode_;
        keeper = keeper_;
    }

    /// @notice Keeper delivers a CCTP attestation: mints USDC to this relay, then forwards to target.
    /// @param message The CCTP burn message bytes (from MessageSent event on source chain).
    /// @param attestation The Circle attestation signature(s).
    /// @param transferId The mesh transfer ID (for event tracking and MeshNode.receiveReturn).
    /// @param srcChainId The source chain ID (CCTP domain, e.g., 6 for Base, 3 for Arbitrum).
    /// @param srcPeer The source peer address as bytes32 (for MeshNode.receiveReturn validation).
    function deliver(
        bytes calldata message,
        bytes calldata attestation,
        bytes32 transferId,
        uint64 srcChainId,
        bytes32 srcPeer
    ) external {
        if (msg.sender != keeper) revert Unauthorized();

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        // Submit attestation — CCTP mints USDC to this contract (we are the mintRecipient)
        bool success = IMessageTransmitterV2(messageTransmitter).receiveMessage(message, attestation);
        if (!success) revert DeliveryFailed();

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 minted = balanceAfter - balanceBefore;
        if (minted == 0) revert ZeroAmount();

        // Approve target to pull tokens
        IERC20(asset).forceApprove(target, minted);

        if (mode == MODE_CUSTODIAN) {
            // Destination chain: deliver to MeshCustodian
            MeshCustodian(payable(target)).onBridgeIn(srcChainId, minted, transferId);
        } else {
            // Source chain: deliver return to MeshNode
            IMeshNode(target).receiveReturn(transferId, srcChainId, srcPeer, minted);
        }

        // Clear approval
        IERC20(asset).forceApprove(target, 0);

        emit Delivered(transferId, target, minted, mode);
    }

    /// @notice Governance updates the keeper address.
    function setKeeper(address newKeeper) external {
        if (msg.sender != governance) revert Unauthorized();
        if (newKeeper == address(0)) revert InvalidConfiguration();
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Rescue any stuck tokens (governance only).
    function rescue(address token, address to, uint256 amount) external {
        if (msg.sender != governance) revert Unauthorized();
        if (to == address(0)) revert InvalidConfiguration();
        IERC20(token).safeTransfer(to, amount);
    }

    receive() external payable {}
}
