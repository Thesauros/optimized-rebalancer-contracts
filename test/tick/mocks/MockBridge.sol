// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeAdapter} from "../../../contracts/crosschain/interfaces/IBridgeAdapter.sol";

interface IReceiveBridge {
    function receiveBridge(address adapter, bytes calldata payload) external returns (bytes32, uint256);
}

/**
 * @notice Shared "wire" between mock adapters in one EVM. Tokens sit here while a
 *         message is in flight. Delivery is explicit, so tests control delay.
 *         Knobs model the adversarial bridges of the brief: a delivery fee
 *         (FeeChargingBridge), redelivery (DuplicateBridgeMessage).
 */
contract MockBridgeHub {
    using SafeERC20 for IERC20;

    struct Message {
        bytes32 transferId;
        uint64 srcChainId;
        address srcAgent;
        address dstAdapter;
        address dstAgent;
        uint256 amount;
        uint256 minReceive;
        bool delivered;
    }

    IERC20 public immutable asset;
    Message[] internal _messages;
    uint256 public feeBps;
    bool public allowRedelivery;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setAllowRedelivery(bool allowed) external {
        allowRedelivery = allowed;
    }

    function post(Message memory m) external returns (uint256 index) {
        index = _messages.length;
        _messages.push(m);
    }

    /// @dev Pays the destination agent (amount - fee). The fee stays on the wire.
    function take(uint256 index) external returns (Message memory m) {
        m = _messages[index];
        require(m.dstAdapter == msg.sender, "wrong adapter");
        require(!m.delivered || allowRedelivery, "delivered");
        _messages[index].delivered = true;
        uint256 fee = (m.amount * feeBps) / 10_000;
        asset.safeTransfer(m.dstAgent, m.amount - fee);
    }

    function message(uint256 index) external view returns (Message memory) {
        return _messages[index];
    }

    function count() external view returns (uint256) {
        return _messages.length;
    }
}

/// @notice Honest mock adapter: agent-only send/finalize, carries ids, pulls exact amount.
contract MockBridgeAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable agent;
    MockBridgeHub public immutable hub;
    uint64 public immutable localChainId;
    mapping(uint64 chainId => address) public remoteAdapter;

    constructor(address asset_, address agent_, MockBridgeHub hub_, uint64 localChainId_) {
        asset = asset_;
        agent = agent_;
        hub = hub_;
        localChainId = localChainId_;
    }

    function setRemote(uint64 chainId, address adapter) external {
        remoteAdapter[chainId] = adapter;
    }

    function send(
        bytes32 transferId,
        uint256 amount,
        uint64 dstChainId,
        address dstAgent,
        uint256 minReceive
    ) external payable virtual {
        require(msg.sender == agent, "only agent");
        IERC20(asset).safeTransferFrom(msg.sender, address(hub), amount);
        hub.post(
            MockBridgeHub.Message({
                transferId: transferId,
                srcChainId: localChainId,
                srcAgent: msg.sender,
                dstAdapter: remoteAdapter[dstChainId],
                dstAgent: dstAgent,
                amount: amount,
                minReceive: minReceive,
                delivered: false
            })
        );
    }

    function finalize(
        bytes calldata payload
    ) external virtual returns (bytes32 transferId, uint64 srcChainId, address srcAgent) {
        require(msg.sender == agent, "only agent");
        MockBridgeHub.Message memory m = hub.take(abi.decode(payload, (uint256)));
        return (m.transferId, m.srcChainId, m.srcAgent);
    }
}

/// @notice Pulls less than asked on send: the agent's measured-debit check must catch it.
contract ShortPullAdapter is MockBridgeAdapter {
    using SafeERC20 for IERC20;

    constructor(address asset_, address agent_, MockBridgeHub hub_, uint64 localChainId_)
        MockBridgeAdapter(asset_, agent_, hub_, localChainId_)
    {}

    function send(bytes32, uint256 amount, uint64, address, uint256) external payable override {
        IERC20(asset).safeTransferFrom(msg.sender, address(hub), amount - 1);
    }
}

/// @notice Returns an attacker-chosen transfer id / source on finalize.
contract ForgingAdapter is MockBridgeAdapter {
    bytes32 public forgedId;
    uint64 public forgedChain;
    address public forgedAgent;

    constructor(address asset_, address agent_, MockBridgeHub hub_, uint64 localChainId_)
        MockBridgeAdapter(asset_, agent_, hub_, localChainId_)
    {}

    function forge(bytes32 id, uint64 chainId, address srcAgent) external {
        forgedId = id;
        forgedChain = chainId;
        forgedAgent = srcAgent;
    }

    function finalize(bytes calldata payload) external override returns (bytes32, uint64, address) {
        hub.take(abi.decode(payload, (uint256)));
        return (forgedId, forgedChain, forgedAgent);
    }
}

/// @notice Re-enters the agent during finalize.
contract ReentrantAdapter is MockBridgeAdapter {
    bytes public reentryPayload;

    constructor(address asset_, address agent_, MockBridgeHub hub_, uint64 localChainId_)
        MockBridgeAdapter(asset_, agent_, hub_, localChainId_)
    {}

    function setReentry(bytes calldata payload) external {
        reentryPayload = payload;
    }

    function finalize(bytes calldata payload) external override returns (bytes32, uint64, address) {
        IReceiveBridge(agent).receiveBridge(address(this), reentryPayload);
        MockBridgeHub.Message memory m = hub.take(abi.decode(payload, (uint256)));
        return (m.transferId, m.srcChainId, m.srcAgent);
    }
}
