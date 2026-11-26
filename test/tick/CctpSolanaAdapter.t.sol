// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickFixture} from "./TickFixture.sol";
import {FeeCapAsset} from "../unit/PerformanceFeeCap.t.sol";
import {CctpSolanaAdapter} from "../../contracts/crosschain/bridges/CctpSolanaAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NativeMessengerMock {
    bytes32 public recipient;
    bytes32 public caller;
    bytes public hook;
    uint32 public domain;
    uint32 public finality;
    uint256 public fee;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 d,
        bytes32 r,
        address token,
        bytes32 c,
        uint256 f,
        uint32 ft,
        bytes calldata h
    ) external {
        IERC20(token).transferFrom(msg.sender, address(0xdead), amount);
        domain = d;
        recipient = r;
        caller = c;
        fee = f;
        finality = ft;
        hook = h;
    }
}

contract NativeTransmitterMock {
    FeeCapAsset public token;
    address public recipient;
    mapping(bytes32 => bool) public used;

    constructor(FeeCapAsset t, address r) {
        token = t;
        recipient = r;
    }

    function localDomain() external pure returns (uint32) {
        return 6;
    }

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool) {
        require(keccak256(attestation) == keccak256(hex"1234"), "bad attestation");
        bytes32 nonce = keccak256(message);
        require(!used[nonce], "nonce used");
        used[nonce] = true;
        token.mint(recipient, 9_990_000);
        return true;
    }
}

contract CctpSolanaAdapterTest is TickFixture {
    uint64 constant NATIVE = 0x8000000000000005;
    bytes32 constant SOL_AGENT = keccak256("native agent with all 256 bits");
    bytes32 constant SOL_TOKEN = keccak256("native token account with all 256 bits");
    bytes32 constant SOL_MINT = keccak256("native USDC mint");
    bytes32 constant SOL_TM = keccak256("native Circle program");
    bytes32 constant NATIVE_ROUTE = keccak256("base-solana");
    CctpSolanaAdapter native;
    NativeMessengerMock messenger;
    NativeTransmitterMock transmitter;

    function setUp() public override {
        super.setUp();
        messenger = new NativeMessengerMock();
        transmitter = new NativeTransmitterMock(usdc, address(hubAgent));
        native = new CctpSolanaAdapter(
            address(usdc),
            address(hubAgent),
            address(messenger),
            address(transmitter),
            SOL_AGENT,
            SOL_TOKEN,
            SOL_MINT,
            SOL_TM
        );
        hubAgent.setAdapter(address(native), true);
        hubAgent.setPeer(NATIVE, native.remoteAlias(), true);
        hubAgent.addRoute(
            NATIVE_ROUTE, address(native), NATIVE, native.remoteAlias(), 10, uint128(100 * ONE), uint128(200 * ONE), 0
        );
        _seedSystem(1_000 * ONE, 0);
        _advance(60);
        _tick();
    }

    function word(bytes memory b, uint256 at, bytes32 v) internal pure {
        assembly { mstore(add(add(b, 32), at), v) }
    }

    function message(bytes32 transferId) internal view returns (bytes memory b) {
        b = new bytes(440);
        word(b, 0, bytes32(uint256(1) << 224));
        word(b, 4, bytes32(uint256(5) << 224));
        word(b, 8, bytes32(uint256(6) << 224));
        word(b, 44, SOL_TM);
        word(b, 76, bytes32(uint256(uint160(address(messenger)))));
        word(b, 108, bytes32(uint256(uint160(address(native)))));
        word(b, 144, bytes32(uint256(2000) << 224));
        word(b, 148, bytes32(uint256(1) << 224));
        word(b, 152, SOL_MINT);
        word(b, 184, bytes32(uint256(uint160(address(hubAgent)))));
        word(b, 216, bytes32(uint256(10 * ONE)));
        word(b, 248, SOL_AGENT);
        word(b, 376, transferId);
        word(b, 408, SOL_AGENT);
    }

    function test_baseToSolanaUsesFullNativeKeysAndExistingMeasuredRoute() public {
        usdc.mint(address(hubAgent), 10 * ONE);
        uint256 before = usdc.balanceOf(address(hubAgent));
        vm.prank(executor);
        bytes32 tid = hubAgent.bridgeOut(NATIVE_ROUTE, 10 * ONE, 9_990_000, bytes32(0));
        assertEq(before - usdc.balanceOf(address(hubAgent)), 10 * ONE);
        assertEq(messenger.recipient(), SOL_TOKEN);
        assertEq(messenger.caller(), SOL_AGENT);
        assertEq(messenger.domain(), 5);
        assertEq(messenger.finality(), 2000);
        assertEq(messenger.fee(), 10_000);
        (bytes32 carried, bytes32 source) = abi.decode(messenger.hook(), (bytes32, bytes32));
        assertEq(carried, tid);
        assertEq(source, bytes32(uint256(uint160(address(hubAgent)))));
        assertEq(hubAgent.getSent(tid).dstChainId, NATIVE);
        assertEq(usdc.allowance(address(native), address(messenger)), 0);
    }

    function test_nativeReceiptIsPermissionlessAndAtomicallyMeasured() public {
        bytes32 tid = keccak256("solana send");
        uint256 before = usdc.balanceOf(address(hubAgent));
        vm.prank(attacker);
        (bytes32 got, uint256 amount) = hubAgent.receiveBridge(address(native), abi.encode(message(tid), hex"1234"));
        assertEq(got, tid);
        assertEq(amount, 9_990_000);
        assertEq(usdc.balanceOf(address(hubAgent)) - before, amount);
        assertEq(hubAgent.getReceived(tid).srcChainId, NATIVE);
        vm.expectRevert();
        hubAgent.receiveBridge(address(native), abi.encode(message(tid), hex"1234"));
    }

    function test_fullNativeIdentityIsAuthenticatedBeforeAliasProjection() public {
        uint256[12] memory offsets = [uint256(0), 4, 8, 44, 76, 108, 144, 148, 152, 184, 248, 408];
        for (uint256 i; i < offsets.length; i++) {
            bytes memory b = message(keccak256(abi.encode(i)));
            b[offsets[i]] ^= bytes1(uint8(0x40));
            if (offsets[i] == 144) {
                b[144] = 0;
                b[145] = 0;
                b[146] = bytes1(uint8(3));
                b[147] = bytes1(uint8(0xe8));
            }
            vm.expectRevert(CctpSolanaAdapter.InvalidMessage.selector);
            hubAgent.receiveBridge(address(native), abi.encode(b, hex"1234"));
        }
    }

    function test_cannotBypassAgentToMintWithoutAccounting() public {
        vm.expectRevert(CctpSolanaAdapter.Unauthorized.selector);
        native.finalize(abi.encode(message(keccak256("id")), hex"1234"));
    }

    function test_aliasIsNamespacedHashInsteadOfTruncatedNativeKey() public view {
        assertEq(
            native.accountingAlias(hex"6161616161616161616161616161616161616161616161616161616161616161"),
            address(bytes20(hex"3bd1541680c1f5b8be5323ae338bc5ba3f3fa133"))
        );
        assertEq(
            native.remoteAlias(),
            address(uint160(uint256(keccak256(abi.encodePacked("thesauros.solana.identity.v1:", SOL_AGENT)))))
        );
        assertTrue(native.remoteAlias() != address(uint160(uint256(SOL_AGENT))));
    }

    function test_existingRouteFeeAndAmountLimitsStillApply() public {
        usdc.mint(address(hubAgent), 200 * ONE);
        vm.startPrank(executor);
        vm.expectRevert();
        hubAgent.bridgeOut(NATIVE_ROUTE, 101 * ONE, 101 * ONE, bytes32(0));
        vm.expectRevert();
        hubAgent.bridgeOut(NATIVE_ROUTE, 10 * ONE, 9 * ONE, bytes32(0));
        vm.stopPrank();
    }

    function test_invalidAttestationRollsBackMintAndReceipt() public {
        bytes32 tid = keccak256("invalid sig");
        uint256 before = usdc.balanceOf(address(hubAgent));
        vm.expectRevert();
        hubAgent.receiveBridge(address(native), abi.encode(message(tid), hex"00"));
        assertEq(usdc.balanceOf(address(hubAgent)), before);
        assertEq(hubAgent.getReceived(tid).receivedAt, 0);
    }
}
