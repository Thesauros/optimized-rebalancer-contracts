// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMeshBridgeAdapter} from "../interfaces/IMeshBridgeAdapter.sol";
import {ITokenMessengerV2} from "./ITokenMessengerV2.sol";

/// @title CCTPMeshBridgeAdapter
/// @notice IMeshBridgeAdapter implementation using Circle CCTP V2 for USDC transfers.
///         Burns USDC on the source chain via CCTP; a relay keeper delivers the
///         attestation on the destination chain, minting USDC to the CCTPRelayReceiver.
///
///         Deployed on BOTH chains (Base and Arbitrum). Each instance is configured
///         with the destination domain and the relay receiver address on that domain.
///
///         Flow:
///           1. MeshNode.bridgeOut / MeshCustodian.bridgeBack calls send()
///           2. send() burns USDC via CCTP depositForBurn
///           3. Circle's Iris attestation service signs the burn message
///           4. Keeper calls relay.deliver() on the destination chain
///           5. Relay calls MessageTransmitter.receiveMessage (mints USDC to relay)
///           6. Relay calls MeshCustodian.onBridgeIn or MeshNode.receiveReturn
///
///         The `credited` return value is the burn amount minus CCTP fee.
///         For standard transfers (maxFee=0), credited = amount (no fee).
contract CCTPMeshBridgeAdapter is IMeshBridgeAdapter {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error Unauthorized();
    error InvalidConfiguration();
    error BurnFailed();

    // ============ Immutables ============
    address public immutable governance;
    address public immutable tokenMessenger;
    uint32 public immutable destinationDomain;

    // ============ Storage ============
    /// @notice Relay receiver address on destination chain (as bytes32). Configurable by governance.
    bytes32 public relayPeer;
    /// @notice Maps transferId -> CCTP nonce for relay tracking.
    mapping(bytes32 => uint64) public transferNonces;
    /// @notice Maps transferId -> amount burned (for relay verification).
    mapping(bytes32 => uint256) public transferAmounts;

    event CCTPBurn(
        bytes32 indexed transferId,
        uint64 indexed nonce,
        address asset,
        uint256 amount,
        uint32 destinationDomain,
        bytes32 relayPeer
    );

    constructor(
        address governance_,
        address tokenMessenger_,
        uint32 destinationDomain_,
        bytes32 relayPeer_
    ) {
        if (governance_ == address(0) || tokenMessenger_.code.length == 0) revert InvalidConfiguration();
        if (relayPeer_ == bytes32(0)) revert InvalidConfiguration();
        governance = governance_;
        tokenMessenger = tokenMessenger_;
        destinationDomain = destinationDomain_;
        relayPeer = relayPeer_;
    }

    /// @inheritdoc IMeshBridgeAdapter
    /// @dev Burns `amount` of `asset` via CCTP V2. The `destinationPeer` parameter
    ///      from IMeshBridgeAdapter is ignored — CCTP always mints to the configured
    ///      relayPeer. The relay then routes to the correct MeshNode/MeshCustodian.
    ///
    ///      `credited` = amount (CCTP standard transfers have no protocol fee).
    ///      If CCTP V2 maxFee > 0 is used in the future, credited will be reduced.
    function send(
        bytes32 transferId,
        address asset,
        uint256 amount,
        uint256,
        bytes32,
        uint256
    ) external payable returns (uint256 credited) {
        if (amount == 0) revert InvalidConfiguration();

        // Pull tokens from caller (MeshNode or MeshCustodian)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve TokenMessenger to burn
        IERC20(asset).forceApprove(tokenMessenger, amount);

        // Burn via CCTP V2 (standard transfer, no fee, no destination caller restriction)
        // Using V1-compatible depositForBurn for simplicity — any address can relay
        uint64 nonce = ITokenMessengerV2(tokenMessenger).depositForBurn(
            amount,
            destinationDomain,
            relayPeer, // mint to relay on destination
            asset
        );

        // Store for relay tracking
        transferNonces[transferId] = nonce;
        transferAmounts[transferId] = amount;

        emit CCTPBurn(transferId, nonce, asset, amount, destinationDomain, relayPeer);

        // CCTP standard transfer: no fee, credited = amount
        credited = amount;
    }

    /// @notice Governance can update the relay peer (e.g., if relay is redeployed).
    function setRelayPeer(bytes32 newPeer) external {
        if (msg.sender != governance) revert Unauthorized();
        if (newPeer == bytes32(0)) revert InvalidConfiguration();
        relayPeer = newPeer;
    }
}
