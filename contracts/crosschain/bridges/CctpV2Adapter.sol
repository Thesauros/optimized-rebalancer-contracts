// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);

    function localDomain() external view returns (uint32);
}

/**
 * @title CctpV2Adapter
 * @notice Circle CCTP V2 transport for one ChainAgent (USDC burn/mint).
 *
 * @dev Send: burns via `depositForBurnWithHook` with
 *        mintRecipient     = destination agent (from the agent's fixed route),
 *        destinationCaller = the peer adapter on the destination domain,
 *        hookData          = abi.encode(transferId, source agent).
 *      Receive: only the agent may call `finalize`; only this adapter may call
 *      `receiveMessage` for messages addressed to it (CCTP enforces
 *      destinationCaller), so no mint can reach the agent unrecorded. The burn's
 *      messageSender must be the registered peer adapter of the source domain,
 *      which authenticates the hookData.
 *
 *      Byte offsets were checked against circlefin/evm-cctp-contracts
 *      (`src/messages/v2/MessageV2.sol`, `BurnMessageV2.sol`, `BurnMessage.sol`,
 *      commit a92a2b4): header 148 bytes; burn body mintRecipient at byte 36,
 *      messageSender at byte 100, hookData at byte 228.
 */
contract CctpV2Adapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant HEADER_LENGTH = 148;
    uint256 internal constant SOURCE_DOMAIN_INDEX = 4;
    uint256 internal constant BODY_MINT_RECIPIENT_INDEX = 36;
    uint256 internal constant BODY_MESSAGE_SENDER_INDEX = 100;
    uint256 internal constant BODY_HOOK_DATA_INDEX = 228;
    uint256 internal constant HOOK_DATA_LENGTH = 64;

    error Unauthorized();
    error InvalidConfig();
    error UnknownRemote();
    error InvalidMessage();
    error ReceiveFailed();
    error NativeFeeNotAccepted();

    event RemoteSet(uint64 indexed chainId, uint32 domain, address remoteAdapter);
    event Sent(bytes32 indexed transferId, uint32 indexed destinationDomain, address dstAgent, uint256 amount, uint256 maxFee);

    struct Remote {
        uint32 domain;
        address adapter;
        bool set;
    }

    address public immutable override asset;
    address public immutable agent;
    address public immutable governance;
    ITokenMessengerV2 public immutable tokenMessenger;
    IMessageTransmitterV2 public immutable messageTransmitter;
    uint32 public immutable minFinalityThreshold;

    mapping(uint64 chainId => Remote) public remotes;
    mapping(uint32 domain => uint64 chainId) public chainIdOfDomain;

    constructor(
        address asset_,
        address agent_,
        address governance_,
        address tokenMessenger_,
        address messageTransmitter_,
        uint32 minFinalityThreshold_
    ) {
        if (
            asset_ == address(0) ||
            agent_ == address(0) ||
            governance_ == address(0) ||
            tokenMessenger_.code.length == 0 ||
            messageTransmitter_.code.length == 0
        ) revert InvalidConfig();
        asset = asset_;
        agent = agent_;
        governance = governance_;
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        messageTransmitter = IMessageTransmitterV2(messageTransmitter_);
        minFinalityThreshold = minFinalityThreshold_;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert Unauthorized();
        _;
    }

    /// @notice Registers the CCTP domain and peer adapter for a chain. Governance
    ///         (Timelock) only; a changed peer should come with a new route id.
    function setRemote(uint64 chainId, uint32 domain, address remoteAdapter) external {
        if (msg.sender != governance) revert Unauthorized();
        if (chainId == 0 || chainId == block.chainid || remoteAdapter == address(0)) {
            revert InvalidConfig();
        }
        remotes[chainId] = Remote(domain, remoteAdapter, true);
        chainIdOfDomain[domain] = chainId;
        emit RemoteSet(chainId, domain, remoteAdapter);
    }

    /// @inheritdoc IBridgeAdapter
    function send(
        bytes32 transferId,
        uint256 amount,
        uint64 dstChainId,
        address dstAgent,
        uint256 minReceive
    ) external payable onlyAgent {
        // CCTP charges its fee in the burned token; native value would be stranded here
        if (msg.value != 0) revert NativeFeeNotAccepted();
        Remote memory r = remotes[dstChainId];
        if (!r.set) revert UnknownRemote();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(tokenMessenger), amount);
        uint256 maxFee = amount - minReceive;
        tokenMessenger.depositForBurnWithHook(
            amount,
            r.domain,
            _toBytes32(dstAgent),
            asset,
            _toBytes32(r.adapter),
            maxFee,
            minFinalityThreshold,
            abi.encode(transferId, msg.sender)
        );
        IERC20(asset).forceApprove(address(tokenMessenger), 0);
        emit Sent(transferId, r.domain, dstAgent, amount, maxFee);
    }

    /**
     * @inheritdoc IBridgeAdapter
     * @param payload abi.encode(bytes message, bytes attestation)
     */
    function finalize(
        bytes calldata payload
    ) external onlyAgent returns (bytes32 transferId, uint64 srcChainId, address srcAgent) {
        (bytes memory message, bytes memory attestation) = abi.decode(payload, (bytes, bytes));
        if (message.length != HEADER_LENGTH + BODY_HOOK_DATA_INDEX + HOOK_DATA_LENGTH) {
            revert InvalidMessage();
        }

        uint32 sourceDomain = uint32(bytes4(_word(message, SOURCE_DOMAIN_INDEX)));
        srcChainId = chainIdOfDomain[sourceDomain];
        Remote memory r = remotes[srcChainId];
        if (srcChainId == 0 || !r.set || r.domain != sourceDomain) revert UnknownRemote();

        address mintRecipient = _addr(_word(message, HEADER_LENGTH + BODY_MINT_RECIPIENT_INDEX));
        address messageSender = _addr(_word(message, HEADER_LENGTH + BODY_MESSAGE_SENDER_INDEX));
        if (mintRecipient != agent || messageSender != r.adapter) revert InvalidMessage();

        transferId = _word(message, HEADER_LENGTH + BODY_HOOK_DATA_INDEX);
        srcAgent = _addr(_word(message, HEADER_LENGTH + BODY_HOOK_DATA_INDEX + 32));

        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
    }

    function _word(bytes memory b, uint256 offset) internal pure returns (bytes32 w) {
        if (offset + 32 > b.length) revert InvalidMessage();
        assembly {
            w := mload(add(add(b, 32), offset))
        }
    }

    function _addr(bytes32 w) internal pure returns (address) {
        if (uint256(w) >> 160 != 0) revert InvalidMessage();
        return address(uint160(uint256(w)));
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
