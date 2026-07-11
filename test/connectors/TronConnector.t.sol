// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAssetBridge} from "../../contracts/connectors/interfaces/IAssetBridge.sol";
import {ICrossChainMessenger} from "../../contracts/connectors/interfaces/ICrossChainMessenger.sol";
import {ConnectorCodec} from "../../contracts/connectors/libraries/ConnectorCodec.sol";
import {EvmTronConnector} from "../../contracts/connectors/EvmTronConnector.sol";
import {TronGateway} from "../../contracts/connectors/TronGateway.sol";
import {TronTUSDT} from "../../contracts/connectors/TronTUSDT.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract MockVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20Metadata private immutable _asset;

    constructor(IERC20Metadata asset_) ERC20("Mock Thesauros USDT", "mtUSDT") {
        _asset = asset_;
    }

    function decimals() public view override returns (uint8) {
        return _asset.decimals();
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        IERC20(address(_asset)).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) revert();
        assets = shares;
        _burn(owner, shares);
        IERC20(address(_asset)).safeTransfer(receiver, assets);
    }
}

contract MockAssetBridge is IAssetBridge {
    using SafeERC20 for IERC20;

    struct Transfer {
        address token;
        address sender;
        uint256 amount;
        uint32 destinationChain;
        bytes32 receiver;
        bytes payload;
    }

    uint256 public nextId;
    mapping(bytes32 transferId => Transfer) private _transfers;

    function bridgeAsset(
        address token,
        uint256 amount,
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address
    ) external payable returns (bytes32 transferId) {
        transferId = keccak256(abi.encode(++nextId, msg.sender, payload));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _transfers[transferId] = Transfer({
            token: token,
            sender: msg.sender,
            amount: amount,
            destinationChain: destinationChain,
            receiver: receiver,
            payload: payload
        });
    }

    function deliverDeposit(bytes32 transferId, EvmTronConnector connector) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).forceApprove(address(connector), transfer.amount);
        connector.receiveBridgedDeposit(transfer.amount, transfer.payload);
        IERC20(transfer.token).forceApprove(address(connector), 0);
    }

    function deliverDepositAmount(
        bytes32 transferId,
        uint256 amount,
        EvmTronConnector connector
    ) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).forceApprove(address(connector), amount);
        connector.receiveBridgedDeposit(amount, transfer.payload);
        IERC20(transfer.token).forceApprove(address(connector), 0);
    }

    function deliverWithdrawal(bytes32 transferId, TronGateway gateway) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).forceApprove(address(gateway), transfer.amount);
        gateway.receiveBridgedWithdrawal(transfer.amount, transfer.payload);
        IERC20(transfer.token).forceApprove(address(gateway), 0);
    }

    function refundDeposit(bytes32 transferId, TronGateway gateway) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).forceApprove(address(gateway), transfer.amount);
        gateway.receiveBridgedDepositRefund(transfer.amount, transfer.payload);
        IERC20(transfer.token).forceApprove(address(gateway), 0);
    }

    function deliverWithdrawalAmount(
        bytes32 transferId,
        uint256 amount,
        TronGateway gateway
    ) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).forceApprove(address(gateway), amount);
        gateway.receiveBridgedWithdrawal(amount, transfer.payload);
        IERC20(transfer.token).forceApprove(address(gateway), 0);
    }

    function cancelWithdrawal(
        bytes32 transferId,
        EvmTronConnector connector
    ) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).safeTransfer(address(connector), transfer.amount);
    }

    function cancelDeposit(bytes32 transferId, TronGateway gateway) external {
        Transfer storage transfer = _transfers[transferId];
        IERC20(transfer.token).safeTransfer(address(gateway), transfer.amount);
    }

    function transferData(
        bytes32 transferId
    ) external view returns (address token, uint256 amount, bytes memory payload) {
        Transfer storage transfer = _transfers[transferId];
        return (transfer.token, transfer.amount, transfer.payload);
    }
}

contract MockMessenger is ICrossChainMessenger {
    struct Message {
        address sender;
        uint32 destinationChain;
        bytes32 receiver;
        bytes payload;
    }

    uint256 public nextId;
    mapping(bytes32 messageId => Message) private _messages;

    function sendMessage(
        uint32 destinationChain,
        bytes32 receiver,
        bytes calldata payload,
        address
    ) external payable returns (bytes32 messageId) {
        messageId = keccak256(abi.encode(++nextId, msg.sender, payload));
        _messages[messageId] = Message({
            sender: msg.sender,
            destinationChain: destinationChain,
            receiver: receiver,
            payload: payload
        });
    }

    function deliverToEvm(
        bytes32 messageId,
        uint32 sourceChain,
        EvmTronConnector connector
    ) external {
        Message storage message = _messages[messageId];
        connector.receiveMessage(
            sourceChain,
            bytes32(uint256(uint160(message.sender))),
            message.payload
        );
    }

    function deliverToTron(
        bytes32 messageId,
        uint32 sourceChain,
        TronGateway gateway
    ) external {
        Message storage message = _messages[messageId];
        gateway.receiveMessage(
            sourceChain,
            bytes32(uint256(uint160(message.sender))),
            message.payload
        );
    }

    function messagePayload(bytes32 messageId) external view returns (bytes memory) {
        return _messages[messageId].payload;
    }
}

contract TronConnectorTests is Test {
    uint32 private constant EVM_CHAIN = 8453;
    uint32 private constant TRON_CHAIN = 100000026;
    uint256 private constant DEPOSIT_ASSETS = 1_000e6;

    address private alice = makeAddr("alice");
    address private owner = makeAddr("owner");

    MockUSDT private usdt;
    MockVault private vault;
    MockAssetBridge private bridge;
    MockMessenger private messenger;
    EvmTronConnector private evmConnector;
    TronGateway private tronGateway;
    TronTUSDT private tUsdt;

    function setUp() public {
        usdt = new MockUSDT();
        vault = new MockVault(usdt);
        bridge = new MockAssetBridge();
        messenger = new MockMessenger();

        uint256 nonce = vm.getNonce(address(this));
        address predictedEvmConnector = vm.computeCreateAddress(address(this), nonce);
        address predictedTronGateway = vm.computeCreateAddress(address(this), nonce + 1);

        evmConnector = new EvmTronConnector(
            owner,
            address(vault),
            address(bridge),
            address(bridge),
            address(messenger),
            TRON_CHAIN,
            _addressToBytes32(predictedTronGateway)
        );
        tronGateway = new TronGateway(
            owner,
            address(usdt),
            address(bridge),
            address(bridge),
            address(messenger),
            EVM_CHAIN,
            _addressToBytes32(address(evmConnector))
        );
        tUsdt = tronGateway.tUSDT();

        assertEq(address(evmConnector), predictedEvmConnector);
        assertEq(address(tronGateway), predictedTronGateway);

        usdt.mint(alice, DEPOSIT_ASSETS);
    }

    function testDepositMintsOnlyAfterEvmInvestmentAndAck() public {
        (bytes32 requestId, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);

        assertEq(tUsdt.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(evmConnector)), 0);

        bridge.deliverDeposit(bridgeTransferId, evmConnector);

        assertEq(vault.balanceOf(address(evmConnector)), DEPOSIT_ASSETS);
        assertEq(evmConnector.allocatedShares(), DEPOSIT_ASSETS);
        assertEq(tUsdt.balanceOf(alice), 0);

        bytes32 ackId = evmConnector.sendDepositAck(requestId);
        messenger.deliverToTron(ackId, EVM_CHAIN, tronGateway);

        assertEq(tUsdt.balanceOf(alice), DEPOSIT_ASSETS);
        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS);
    }

    function testFullRedeemCycleEscrowsThenBurnsAfterPayout() public {
        _completeDeposit(DEPOSIT_ASSETS);
        uint256 redeemShares = 400e6;

        vm.startPrank(alice);
        tUsdt.approve(address(tronGateway), redeemShares);
        bytes32 requestId = tronGateway.requestRedeem(
            redeemShares,
            redeemShares,
            redeemShares,
            alice
        );
        vm.stopPrank();

        assertEq(tUsdt.balanceOf(alice), DEPOSIT_ASSETS - redeemShares);
        assertEq(tUsdt.balanceOf(address(tronGateway)), redeemShares);
        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS);

        (, , , , , , , bytes32 redeemMessageId) = tronGateway.redeems(requestId);
        messenger.deliverToEvm(redeemMessageId, TRON_CHAIN, evmConnector);

        assertEq(evmConnector.reservedRedeemShares(), redeemShares);
        bytes32 withdrawalTransferId = evmConnector.processRedeem(requestId);

        assertEq(vault.balanceOf(address(evmConnector)), DEPOSIT_ASSETS - redeemShares);
        assertEq(evmConnector.allocatedShares(), DEPOSIT_ASSETS - redeemShares);
        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS);

        bridge.deliverWithdrawal(withdrawalTransferId, tronGateway);

        assertEq(usdt.balanceOf(alice), redeemShares);
        assertEq(tUsdt.balanceOf(address(tronGateway)), 0);
        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS - redeemShares);
    }

    function testDuplicateDepositAckCannotMintTwice() public {
        (bytes32 requestId, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);
        bytes32 ackId = evmConnector.sendDepositAck(requestId);

        messenger.deliverToTron(ackId, EVM_CHAIN, tronGateway);
        messenger.deliverToTron(ackId, EVM_CHAIN, tronGateway);

        assertEq(tUsdt.balanceOf(alice), DEPOSIT_ASSETS);
        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS);
    }

    function testAuthenticatedDepositRefundPreventsLateMint() public {
        (bytes32 requestId, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);

        bridge.refundDeposit(bridgeTransferId, tronGateway);

        assertEq(usdt.balanceOf(alice), DEPOSIT_ASSETS);
        assertEq(tUsdt.totalSupply(), 0);

        bytes memory lateAck = ConnectorCodec.encodeDepositAck(requestId, DEPOSIT_ASSETS, 6);
        vm.prank(address(evmConnector));
        bytes32 messageId = messenger.sendMessage(
            TRON_CHAIN,
            _addressToBytes32(address(tronGateway)),
            lateAck,
            address(this)
        );
        vm.expectRevert(TronGateway.InvalidState.selector);
        messenger.deliverToTron(messageId, EVM_CHAIN, tronGateway);
    }

    function testDepositRevertsWhenBridgeOutputMissesMinShares() public {
        vm.startPrank(alice);
        usdt.approve(address(tronGateway), DEPOSIT_ASSETS);
        bytes32 requestId = tronGateway.requestDeposit(
            DEPOSIT_ASSETS,
            DEPOSIT_ASSETS,
            DEPOSIT_ASSETS + 1,
            uint64(block.timestamp + 1 hours),
            alice
        );
        vm.stopPrank();

        (, , , , , , , , bytes32 bridgeTransferId) = tronGateway.deposits(requestId);
        vm.expectRevert(EvmTronConnector.SlippageExceeded.selector);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);

        assertEq(vault.balanceOf(address(evmConnector)), 0);
        assertEq(tUsdt.totalSupply(), 0);
    }

    function testDepositRevertsWhenBridgeOutputMissesMinBaseAssets() public {
        (, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);

        vm.expectRevert(EvmTronConnector.SlippageExceeded.selector);
        bridge.deliverDepositAmount(
            bridgeTransferId,
            DEPOSIT_ASSETS - 1,
            evmConnector
        );

        assertEq(vault.balanceOf(address(evmConnector)), 0);
        assertEq(tUsdt.totalSupply(), 0);
    }

    function testExpiredDepositCannotBeInvestedOnBase() public {
        (, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectRevert(EvmTronConnector.DeadlineExpired.selector);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);

        assertEq(vault.balanceOf(address(evmConnector)), 0);
        assertEq(tUsdt.totalSupply(), 0);
    }

    function testRejectsWrongMessageOrigin() public {
        bytes memory payload = ConnectorCodec.encodeDepositAck(bytes32(uint256(1)), 1, 6);
        vm.expectRevert(TronGateway.InvalidMessageOrigin.selector);
        tronGateway.receiveMessage(EVM_CHAIN, _addressToBytes32(address(evmConnector)), payload);
    }

    function testRejectsDepositAckWithDifferentShareDecimals() public {
        (bytes32 requestId, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);

        vm.prank(address(evmConnector));
        bytes32 messageId = messenger.sendMessage(
            TRON_CHAIN,
            _addressToBytes32(address(tronGateway)),
            ConnectorCodec.encodeDepositAck(requestId, DEPOSIT_ASSETS, 18),
            address(this)
        );

        vm.expectRevert(TronGateway.InvalidRequest.selector);
        messenger.deliverToTron(messageId, EVM_CHAIN, tronGateway);
        assertEq(tUsdt.totalSupply(), 0);
    }

    function testDuplicateRedeemMessageDoesNotReserveTwice() public {
        _completeDeposit(DEPOSIT_ASSETS);
        uint256 shares = 250e6;

        vm.startPrank(alice);
        tUsdt.approve(address(tronGateway), shares);
        bytes32 requestId = tronGateway.requestRedeem(
            shares,
            shares,
            shares,
            alice
        );
        vm.stopPrank();

        (, , , , , , , bytes32 messageId) = tronGateway.redeems(requestId);
        messenger.deliverToEvm(messageId, TRON_CHAIN, evmConnector);
        messenger.deliverToEvm(messageId, TRON_CHAIN, evmConnector);

        assertEq(evmConnector.reservedRedeemShares(), shares);
    }

    function testWithdrawalBelowNetMinimumDoesNotBurnShares() public {
        _completeDeposit(DEPOSIT_ASSETS);
        uint256 shares = 300e6;

        vm.startPrank(alice);
        tUsdt.approve(address(tronGateway), shares);
        bytes32 requestId = tronGateway.requestRedeem(
            shares,
            shares,
            shares,
            alice
        );
        vm.stopPrank();

        (, , , , , , , bytes32 messageId) = tronGateway.redeems(requestId);
        messenger.deliverToEvm(messageId, TRON_CHAIN, evmConnector);
        bytes32 transferId = evmConnector.processRedeem(requestId);

        vm.expectRevert(TronGateway.SlippageExceeded.selector);
        bridge.deliverWithdrawalAmount(transferId, shares - 1, tronGateway);

        assertEq(tUsdt.totalSupply(), DEPOSIT_ASSETS);
        assertEq(tUsdt.balanceOf(address(tronGateway)), shares);
    }

    function testOwnerCanRetryCancelledWithdrawalBridge() public {
        _completeDeposit(DEPOSIT_ASSETS);
        uint256 shares = 300e6;

        vm.startPrank(alice);
        tUsdt.approve(address(tronGateway), shares);
        bytes32 requestId = tronGateway.requestRedeem(
            shares,
            shares,
            shares,
            alice
        );
        vm.stopPrank();

        (, , , , , , , bytes32 messageId) = tronGateway.redeems(requestId);
        messenger.deliverToEvm(messageId, TRON_CHAIN, evmConnector);
        bytes32 cancelledTransferId = evmConnector.processRedeem(requestId);
        bridge.cancelWithdrawal(cancelledTransferId, evmConnector);

        vm.prank(owner);
        bytes32 retryTransferId = evmConnector.retryRedeemBridge(requestId);

        assertTrue(retryTransferId != cancelledTransferId);
        assertEq(usdt.balanceOf(address(evmConnector)), 0);
        (, , , , , , bytes32 storedTransferId) = evmConnector.redeems(requestId);
        assertEq(storedTransferId, retryTransferId);
    }

    function testPauseStopsNewRequestsButNotOutstandingAck() public {
        (bytes32 requestId, bytes32 bridgeTransferId) = _requestDeposit(DEPOSIT_ASSETS);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);

        vm.prank(owner);
        tronGateway.pause();

        vm.startPrank(alice);
        usdt.approve(address(tronGateway), 1);
        vm.expectRevert();
        tronGateway.requestDeposit(1, 1, 1, uint64(block.timestamp + 1 hours), alice);
        vm.stopPrank();

        bytes32 ackId = evmConnector.sendDepositAck(requestId);
        messenger.deliverToTron(ackId, EVM_CHAIN, tronGateway);
        assertEq(tUsdt.balanceOf(alice), DEPOSIT_ASSETS);
    }

    function testCannotRescueBackingTokens() public {
        vm.startPrank(owner);
        vm.expectRevert(TronGateway.BackingTokenRescueForbidden.selector);
        tronGateway.rescueToken(address(usdt), owner, 1);
        vm.expectRevert(TronGateway.BackingTokenRescueForbidden.selector);
        tronGateway.rescueToken(address(tUsdt), owner, 1);
        vm.expectRevert(EvmTronConnector.BackingTokenRescueForbidden.selector);
        evmConnector.rescueToken(address(vault), owner, 1);
        vm.stopPrank();
    }

    function testOwnerCanRetryCancelledDepositBridge() public {
        (bytes32 requestId, bytes32 cancelledTransferId) = _requestDeposit(
            DEPOSIT_ASSETS
        );
        bridge.cancelDeposit(cancelledTransferId, tronGateway);

        vm.prank(owner);
        bytes32 retryTransferId = tronGateway.retryDepositBridge(requestId);

        assertTrue(retryTransferId != cancelledTransferId);
        assertEq(usdt.balanceOf(address(tronGateway)), 0);
        (, , , , , , , , bytes32 storedTransferId) = tronGateway.deposits(
            requestId
        );
        assertEq(storedTransferId, retryTransferId);
    }

    function testCannotUseGatewayBeforePairing() public {
        TronGateway unpaired = new TronGateway(
            owner,
            address(usdt),
            address(bridge),
            address(bridge),
            address(messenger),
            EVM_CHAIN,
            bytes32(0)
        );
        usdt.mint(alice, 1);

        vm.startPrank(alice);
        usdt.approve(address(unpaired), 1);
        vm.expectRevert(TronGateway.InvalidState.selector);
        unpaired.requestDeposit(1, 1, 1, uint64(block.timestamp + 1 hours), alice);
        vm.stopPrank();

        vm.prank(owner);
        unpaired.setEvmConnector(_addressToBytes32(address(evmConnector)));
        assertEq(unpaired.evmConnector(), _addressToBytes32(address(evmConnector)));
    }

    function testFuzzRoundTripMaintainsShareBacking(
        uint256 depositAssets,
        uint256 redeemShares
    ) public {
        depositAssets = bound(depositAssets, 1, DEPOSIT_ASSETS);
        redeemShares = bound(redeemShares, 1, depositAssets);
        _completeDeposit(depositAssets);

        vm.startPrank(alice);
        tUsdt.approve(address(tronGateway), redeemShares);
        bytes32 requestId = tronGateway.requestRedeem(
            redeemShares,
            redeemShares,
            redeemShares,
            alice
        );
        vm.stopPrank();

        (, , , , , , , bytes32 messageId) = tronGateway.redeems(requestId);
        messenger.deliverToEvm(messageId, TRON_CHAIN, evmConnector);
        bytes32 transferId = evmConnector.processRedeem(requestId);
        bridge.deliverWithdrawal(transferId, tronGateway);

        uint256 remainingShares = depositAssets - redeemShares;
        assertEq(vault.balanceOf(address(evmConnector)), remainingShares);
        assertEq(evmConnector.allocatedShares(), remainingShares);
        assertEq(tUsdt.totalSupply(), remainingShares);
        assertEq(tUsdt.balanceOf(address(tronGateway)), 0);
    }

    function _completeDeposit(uint256 assets) private returns (bytes32 requestId) {
        bytes32 bridgeTransferId;
        (requestId, bridgeTransferId) = _requestDeposit(assets);
        bridge.deliverDeposit(bridgeTransferId, evmConnector);
        bytes32 ackId = evmConnector.sendDepositAck(requestId);
        messenger.deliverToTron(ackId, EVM_CHAIN, tronGateway);
    }

    function _requestDeposit(
        uint256 assets
    ) private returns (bytes32 requestId, bytes32 bridgeTransferId) {
        vm.startPrank(alice);
        usdt.approve(address(tronGateway), assets);
        requestId = tronGateway.requestDeposit(
            assets,
            assets,
            assets,
            uint64(block.timestamp + 1 hours),
            alice
        );
        vm.stopPrank();

        (, , , , , , , , bridgeTransferId) = tronGateway.deposits(requestId);
    }

    function _addressToBytes32(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
