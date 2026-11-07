// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ITokenMessengerV2, IMessageTransmitterV2} from "./CctpV2Adapter.sol";

/// @notice Native Solana boundary. Native keys are full bytes32; the address
/// alias is solely an identity in the existing ChainAgent/NavSnapshot v1 ABI.
/// Deploy one immutable adapter per remote agent. Endpoint changes require a
/// new adapter and Timelock route, preventing alias remapping under old transfers.
contract CctpSolanaAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    uint64 public constant SOLANA_ACCOUNTING_ID = 0x8000000000000005;
    uint32 public constant SOLANA_DOMAIN = 5;
    uint32 public constant FINALIZED = 2000;
    uint256 private constant BODY = 148;
    uint256 private constant HOOK = BODY + 228;

    address public immutable override asset;
    address public immutable agent;
    address public immutable remoteAlias;
    bytes32 public immutable remoteAgent;
    bytes32 public immutable remoteTokenAccount;
    bytes32 public immutable remoteMint;
    bytes32 public immutable remoteTokenMessenger;
    ITokenMessengerV2 public immutable tokenMessenger;
    IMessageTransmitterV2 public immutable messageTransmitter;

    error InvalidConfig();
    error Unauthorized();
    error InvalidMessage();
    error ReceiveFailed();

    event Sent(bytes32 indexed transferId, bytes32 indexed nativeRecipient, uint256 amount, uint256 maxFee);

    constructor(
        address asset_,
        address agent_,
        address tokenMessenger_,
        address messageTransmitter_,
        bytes32 remoteAgent_,
        bytes32 remoteTokenAccount_,
        bytes32 remoteMint_,
        bytes32 remoteTokenMessenger_
    ) {
        if (
            asset_.code.length == 0 || agent_ == address(0) || tokenMessenger_.code.length == 0
                || messageTransmitter_.code.length == 0 || remoteAgent_ == bytes32(0)
                || remoteTokenAccount_ == bytes32(0) || remoteMint_ == bytes32(0) || remoteTokenMessenger_ == bytes32(0)
        ) revert InvalidConfig();
        asset = asset_;
        agent = agent_;
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        messageTransmitter = IMessageTransmitterV2(messageTransmitter_);
        remoteAgent = remoteAgent_;
        remoteTokenAccount = remoteTokenAccount_;
        remoteMint = remoteMint_;
        remoteTokenMessenger = remoteTokenMessenger_;
        remoteAlias = accountingAlias(remoteAgent_);
    }

    function accountingAlias(bytes32 nativeKey) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("thesauros.solana.identity.v1:", nativeKey)))));
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert Unauthorized();
        _;
    }

    function send(bytes32 transferId, uint256 amount, uint64 dstChainId, address dstAgent, uint256 minReceive)
        external
        payable
        onlyAgent
    {
        if (
            msg.value != 0 || dstChainId != SOLANA_ACCOUNTING_ID || dstAgent != remoteAlias || transferId == bytes32(0)
                || amount == 0 || amount > type(uint64).max || minReceive == 0 || minReceive > amount
        ) revert InvalidMessage();
        IERC20(asset).safeTransferFrom(agent, address(this), amount);
        IERC20(asset).forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurnWithHook(
            amount,
            SOLANA_DOMAIN,
            remoteTokenAccount,
            asset,
            remoteAgent,
            amount - minReceive,
            FINALIZED,
            abi.encode(transferId, bytes32(uint256(uint160(agent))))
        );
        IERC20(asset).forceApprove(address(tokenMessenger), 0);
        emit Sent(transferId, remoteTokenAccount, amount, amount - minReceive);
    }

    function finalize(bytes calldata payload)
        external
        onlyAgent
        returns (bytes32 transferId, uint64 srcChainId, address srcAgent)
    {
        (bytes memory message, bytes memory attestation) = abi.decode(payload, (bytes, bytes));
        if (message.length != HOOK + 64) revert InvalidMessage();
        // Circle verifies attestation, destination domain, nonce and caller too.
        // Validate all application bindings before calling the mint boundary.
        if (
            uint32(bytes4(_word(message, 0))) != 1 || uint32(bytes4(_word(message, 4))) != SOLANA_DOMAIN
                || uint32(bytes4(_word(message, 8))) != messageTransmitter.localDomain()
                || _word(message, 44) != remoteTokenMessenger
                || _word(message, 76) != bytes32(uint256(uint160(address(tokenMessenger))))
                || _word(message, 108) != bytes32(uint256(uint160(address(this))))
                || uint32(bytes4(_word(message, 144))) < FINALIZED || uint32(bytes4(_word(message, BODY))) != 1
                || _word(message, BODY + 4) != remoteMint
                || _word(message, BODY + 36) != bytes32(uint256(uint160(agent)))
                || _word(message, BODY + 100) != remoteAgent || _word(message, HOOK + 32) != remoteAgent
        ) revert InvalidMessage();
        transferId = _word(message, HOOK);
        if (transferId == bytes32(0)) revert InvalidMessage();
        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        return (transferId, SOLANA_ACCOUNTING_ID, remoteAlias);
    }

    function _word(bytes memory b, uint256 offset) private pure returns (bytes32 w) {
        if (offset + 32 > b.length) revert InvalidMessage();
        assembly { w := mload(add(add(b, 32), offset)) }
    }
}
