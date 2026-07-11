// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDlnSource} from "../../contracts/connectors/interfaces/IDlnSource.sol";
import {BaseDlnAssetBridge} from "../../contracts/connectors/BaseDlnAssetBridge.sol";
import {TronDlnAssetBridge} from "../../contracts/connectors/TronDlnAssetBridge.sol";
import {DeBridgeMessengerAdapter} from "../../contracts/connectors/DeBridgeMessengerAdapter.sol";
import {ConnectorCodec} from "../../contracts/connectors/libraries/ConnectorCodec.sol";

contract AdapterTestUSDC is ERC20 {
    constructor() ERC20("Base USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract MockDlnSource is IDlnSource {
    using SafeERC20 for IERC20;

    uint88 public constant FEE = 0.001 ether;
    OrderCreation private _lastOrder;

    function globalFixedNativeFee() external pure returns (uint88) {
        return FEE;
    }

    function createOrder(
        OrderCreation calldata order,
        bytes calldata,
        uint32,
        bytes calldata
    ) external payable returns (bytes32 orderId) {
        require(msg.value == FEE);
        IERC20(order.giveTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            order.giveAmount
        );
        _lastOrder = order;
        orderId = keccak256(abi.encode(order));
    }

    function lastOrder() external view returns (OrderCreation memory) {
        return _lastOrder;
    }
}

contract MockCallProxy {
    uint256 public submissionChainIdFrom;
    bytes public submissionNativeSender;

    function deliver(
        address target,
        bytes calldata callData,
        uint256 chainId,
        bytes calldata nativeSender
    ) external {
        submissionChainIdFrom = chainId;
        submissionNativeSender = nativeSender;
        (bool success, bytes memory result) = target.call(callData);
        if (!success) assembly {
            revert(add(result, 32), mload(result))
        }
    }
}

contract MockDeBridgeGate {
    uint256 public constant FEE = 0.001 ether;
    address public immutable callProxy;
    bytes public lastTarget;
    bytes public lastCallData;

    constructor(address callProxy_) {
        callProxy = callProxy_;
    }

    function globalFixedNativeFee() external pure returns (uint256) {
        return FEE;
    }

    function sendMessage(
        uint256,
        bytes calldata target,
        bytes calldata callData
    ) external payable returns (bytes32 submissionId) {
        require(msg.value >= FEE);
        lastTarget = target;
        lastCallData = callData;
        submissionId = keccak256(abi.encode(target, callData));
    }
}

contract MockConnectorReceiver {
    uint32 public sourceChain;
    bytes32 public sourceSender;
    bytes public payload;

    function receiveMessage(
        uint32 sourceChain_,
        bytes32 sourceSender_,
        bytes calldata payload_
    ) external {
        sourceChain = sourceChain_;
        sourceSender = sourceSender_;
        payload = payload_;
    }
}

contract BaseAdapterTests is Test {
    uint32 private constant BASE_CHAIN = 8453;
    uint32 private constant TRON_CHAIN = 100000026;
    address private constant TRON_USDT = address(0x1111);
    address private constant TRON_GATEWAY = address(0x2222);
    address private constant TRON_MESSENGER = address(0x3333);

    AdapterTestUSDC private usdc;
    MockDlnSource private source;
    BaseDlnAssetBridge private bridge;

    function setUp() public {
        vm.deal(address(this), 1 ether);
        usdc = new AdapterTestUSDC();
        source = new MockDlnSource();
        bridge = new BaseDlnAssetBridge(
            address(this),
            address(source),
            address(usdc),
            TRON_CHAIN,
            _addressToBytes32(TRON_USDT),
            _addressToBytes32(TRON_GATEWAY),
            1_000_000,
            0
        );
        bridge.setConnector(address(this));
    }

    function testBuildsBoundAtomicDlnWithdrawalOrder() public {
        uint256 amount = 100e6;
        uint256 minTronAssets = 99e6;
        bytes memory payload = ConnectorCodec.encodeWithdrawal(
            bytes32(uint256(7)),
            minTronAssets,
            _addressToBytes32(address(0x4444))
        );
        usdc.mint(address(this), amount);
        usdc.approve(address(bridge), amount);

        bytes32 orderId = bridge.bridgeAsset{value: source.FEE()}(
            address(usdc),
            amount,
            TRON_CHAIN,
            _addressToBytes32(TRON_GATEWAY),
            payload,
            address(this)
        );

        assertTrue(orderId != bytes32(0));
        assertEq(usdc.balanceOf(address(source)), amount);
        IDlnSource.OrderCreation memory order = source.lastOrder();
        assertEq(order.giveTokenAddress, address(usdc));
        assertEq(order.giveAmount, amount);
        assertEq(order.takeTokenAddress, abi.encodePacked(TRON_USDT));
        assertEq(order.takeAmount, minTronAssets);
        assertEq(order.takeChainId, TRON_CHAIN);
        assertEq(order.receiverDst, abi.encodePacked(TRON_GATEWAY));

        BaseDlnAssetBridge.ExternalCallEnvelopeV1 memory envelope = abi.decode(
            order.externalCall,
            (BaseDlnAssetBridge.ExternalCallEnvelopeV1)
        );
        assertEq(envelope.fallbackAddress, TRON_GATEWAY);
        assertEq(envelope.executorAddress, address(0));
        assertEq(envelope.executionFee, 0);
        assertFalse(envelope.allowDelayedExecution);
        assertTrue(envelope.requireSuccessfulExecution);

        BaseDlnAssetBridge.UniversalHookPayload memory hook = abi.decode(
            envelope.payload,
            (BaseDlnAssetBridge.UniversalHookPayload)
        );
        assertEq(hook.to, TRON_GATEWAY);
        assertEq(hook.txGas, 1_000_000);
        assertEq(
            bytes4(hook.callData),
            bytes4(keccak256("receiveBridgedWithdrawal(uint256,bytes)"))
        );
    }

    function testMessengerAuthenticatesRemoteAdapter() public {
        MockCallProxy proxy = new MockCallProxy();
        MockDeBridgeGate gate = new MockDeBridgeGate(address(proxy));
        DeBridgeMessengerAdapter messenger = new DeBridgeMessengerAdapter(
            address(this),
            address(gate),
            TRON_CHAIN,
            _addressToBytes32(TRON_MESSENGER)
        );
        MockConnectorReceiver receiver = new MockConnectorReceiver();
        address sourceApplication = address(0x5555);
        bytes memory payload = hex"1234";
        bytes memory incomingCall = abi.encodeCall(
            messenger.receiveMessage,
            (
                _addressToBytes32(sourceApplication),
                _addressToBytes32(address(receiver)),
                payload
            )
        );

        proxy.deliver(
            address(messenger),
            incomingCall,
            TRON_CHAIN,
            abi.encodePacked(TRON_MESSENGER)
        );

        assertEq(receiver.sourceChain(), TRON_CHAIN);
        assertEq(receiver.sourceSender(), _addressToBytes32(sourceApplication));
        assertEq(receiver.payload(), payload);

        vm.expectRevert(DeBridgeMessengerAdapter.InvalidMessageOrigin.selector);
        proxy.deliver(
            address(messenger),
            incomingCall,
            TRON_CHAIN,
            abi.encodePacked(address(0xdead))
        );
    }

    function testBuildsBoundAtomicDlnDepositOrder() public {
        TronDlnAssetBridge tronBridge = new TronDlnAssetBridge(
            address(this),
            address(source),
            address(usdc),
            BASE_CHAIN,
            _addressToBytes32(address(0x8335)),
            1_000_000,
            0
        );
        tronBridge.setConnector(address(this));

        uint256 amount = 100e6;
        uint256 minBaseAssets = 99e6;
        address baseConnector = address(0x5555);
        bytes memory payload = ConnectorCodec.encodeDeposit(
            bytes32(uint256(8)),
            minBaseAssets,
            98e6,
            uint64(block.timestamp + 1 hours),
            _addressToBytes32(address(0x4444))
        );
        usdc.mint(address(this), amount);
        usdc.approve(address(tronBridge), amount);

        tronBridge.bridgeAsset{value: source.FEE()}(
            address(usdc),
            amount,
            BASE_CHAIN,
            _addressToBytes32(baseConnector),
            payload,
            address(this)
        );

        IDlnSource.OrderCreation memory order = source.lastOrder();
        assertEq(order.giveAmount, amount);
        assertEq(order.takeAmount, minBaseAssets);
        assertEq(order.takeChainId, BASE_CHAIN);
        assertEq(order.receiverDst, abi.encodePacked(baseConnector));
        assertEq(order.allowedCancelBeneficiarySrc, abi.encodePacked(address(this)));

        TronDlnAssetBridge.ExternalCallEnvelopeV1 memory envelope = abi.decode(
            order.externalCall,
            (TronDlnAssetBridge.ExternalCallEnvelopeV1)
        );
        assertEq(envelope.fallbackAddress, baseConnector);
        assertTrue(envelope.requireSuccessfulExecution);

        TronDlnAssetBridge.UniversalHookPayload memory hook = abi.decode(
            envelope.payload,
            (TronDlnAssetBridge.UniversalHookPayload)
        );
        assertEq(hook.to, baseConnector);
        assertEq(
            bytes4(hook.callData),
            bytes4(keccak256("receiveBridgedDeposit(uint256,bytes)"))
        );
    }

    function _addressToBytes32(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
