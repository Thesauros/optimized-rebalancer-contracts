// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMeshBridgeAdapter} from "../../contracts/crosschain/interfaces/IMeshBridgeAdapter.sol";
import {IMeshNode} from "../../contracts/crosschain/interfaces/IMeshNode.sol";

/// @dev TEST ONLY. Manual relaying simulates asynchronous delivery in one EVM.
/// No real bridge authentication, signatures, chain finality or remote yield.
contract MockMeshBridgeAdapter is IMeshBridgeAdapter {
    using SafeERC20 for IERC20;

    struct Message {
        address node;
        address asset;
        uint256 amount;
        uint256 chainId;
        bytes32 peer;
        bool delivered;
    }

    mapping(bytes32 => Message) public messages;
    uint256 public feeBps;
    bool public failSend;
    bool public shortDebit;
    bool public overQuote;
    bool public belowMinimum;
    bytes public sendCallback;
    bytes public returnCallback;
    bool public callbackSucceeded;
    uint256 public nativeFeeReceived;

    function setFee(uint256 value) external { feeBps = value; }
    function setFailSend(bool value) external { failSend = value; }
    function setShortDebit(bool value) external { shortDebit = value; }
    function setOverQuote(bool value) external { overQuote = value; }
    function setBelowMinimum(bool value) external { belowMinimum = value; }
    function setSendCallback(bytes calldata value) external { sendCallback = value; }
    function setReturnCallback(bytes calldata value) external { returnCallback = value; }

    function send(bytes32 id, address asset, uint256 amount, uint256 chainId, bytes32 peer, uint256 minOut)
        external payable returns (uint256 credited)
    {
        require(!failSend, "bridge unavailable");
        credited = amount - amount * feeBps / 10_000;
        if (overQuote) credited = amount + 1;
        if (belowMinimum) credited = minOut - 1;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), shortDebit ? amount - 1 : amount);
        messages[id] = Message(msg.sender, asset, credited, chainId, peer, false);
        nativeFeeReceived += msg.value;
        if (sendCallback.length != 0) (callbackSucceeded,) = msg.sender.call(sendCallback);
    }

    function deliverOutbound(bytes32 id) external {
        Message storage m = messages[id];
        require(m.node != address(0) && !m.delivered, "invalid outbound");
        m.delivered = true;
        IERC20(m.asset).safeTransfer(address(uint160(uint256(m.peer))), m.amount);
    }

    function deliverReturn(bytes32 id, uint256 amount) external {
        Message memory m = messages[id];
        require(m.delivered, "not delivered");
        IERC20 token = IERC20(m.asset);
        address peer = address(uint160(uint256(m.peer)));
        if (amount != 0) token.safeTransferFrom(peer, address(this), amount);
        token.forceApprove(m.node, amount);
        IMeshNode(m.node).receiveReturn(id, m.chainId, m.peer, amount);
        token.forceApprove(m.node, 0);
        if (returnCallback.length != 0) (callbackSucceeded,) = m.node.call(returnCallback);
    }
}
