// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CctpV2Adapter, IMessageTransmitterV2} from "../../contracts/crosschain/bridges/CctpV2Adapter.sol";

/**
 * @notice Verifies CctpV2Adapter against the live CCTP V2 deployment:
 *         - the domains we configure match `localDomain()` on each chain;
 *         - a real `depositForBurnWithHook` on a Base fork emits a message whose
 *           fields our parser reads correctly (recipient, caller, sender, hook);
 *         - a destination adapter accepts that exact message and rejects a
 *           tampered sender.
 *         Attestation cannot be produced in a test, so `receiveMessage` is mocked
 *         on the destination side; everything read from the message is real.
 */
contract CctpV2AdapterForkTest is Test {
    // CCTP V2 (same addresses on every EVM chain), per circlefin/evm-cctp-contracts tests
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint32 internal constant DOMAIN_ETHEREUM = 0;
    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_BASE = 6;
    uint32 internal constant FINALIZED = 2000;

    bytes32 internal constant MESSAGE_SENT = keccak256("MessageSent(bytes)");

    address internal dstAgent = makeAddr("dstAgent");
    address internal dstAdapterAddr;

    function _fork(string memory envName, string memory fallbackUrl) internal returns (bool) {
        string memory url = vm.envOr(envName, fallbackUrl);
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url);
        return true;
    }

    function testDomainsMatchLiveDeployment() public {
        if (_fork("BASE_RPC_URL", "")) {
            assertEq(IMessageTransmitterV2(MESSAGE_TRANSMITTER_V2).localDomain(), DOMAIN_BASE, "Base domain");
        }
        if (_fork("ETHEREUM_RPC_URL", "")) {
            assertEq(IMessageTransmitterV2(MESSAGE_TRANSMITTER_V2).localDomain(), DOMAIN_ETHEREUM, "Ethereum domain");
        }
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        assertEq(IMessageTransmitterV2(MESSAGE_TRANSMITTER_V2).localDomain(), DOMAIN_ARBITRUM, "Arbitrum domain");
    }

    function testRealBurnMessageRoundTrip() public {
        if (!_fork("BASE_RPC_URL", "")) return;

        // source side: this test contract plays the agent
        CctpV2Adapter src = new CctpV2Adapter(USDC_BASE, address(this), address(this), TOKEN_MESSENGER_V2, MESSAGE_TRANSMITTER_V2, FINALIZED);
        // the destination adapter, as it would be deployed on Arbitrum (agent = dstAgent)
        CctpV2Adapter dst = new CctpV2Adapter(USDC_BASE, dstAgent, address(this), TOKEN_MESSENGER_V2, MESSAGE_TRANSMITTER_V2, FINALIZED);
        dstAdapterAddr = address(dst);
        src.setRemote(42161, DOMAIN_ARBITRUM, dstAdapterAddr);

        uint256 amount = 1_000e6;
        deal(USDC_BASE, address(this), amount);
        IERC20(USDC_BASE).approve(address(src), amount);
        bytes32 transferId = keccak256("transfer-1");

        vm.recordLogs();
        src.send(transferId, amount, 42161, dstAgent, amount);
        bytes memory message = _messageSent(vm.getRecordedLogs());

        assertEq(IERC20(USDC_BASE).balanceOf(address(src)), 0, "adapter keeps nothing");
        assertEq(IERC20(USDC_BASE).allowance(address(src), TOKEN_MESSENGER_V2), 0, "approval cleared");

        // header fields from the real message
        assertEq(uint32(bytes4(_slice32(message, 4))), DOMAIN_BASE, "source domain");
        assertEq(uint32(bytes4(_slice32(message, 8))), DOMAIN_ARBITRUM, "destination domain");
        assertEq(_slice32(message, 108), bytes32(uint256(uint160(dstAdapterAddr))), "destinationCaller = peer adapter");
        // burn body
        assertEq(_slice32(message, 148 + 36), bytes32(uint256(uint160(dstAgent))), "mintRecipient = destination agent");
        assertEq(uint256(_slice32(message, 148 + 68)), amount, "amount");
        assertEq(_slice32(message, 148 + 100), bytes32(uint256(uint160(address(src)))), "messageSender = source adapter");
        assertEq(_slice32(message, 148 + 228), transferId, "hook: transfer id");
        assertEq(_slice32(message, 148 + 260), bytes32(uint256(uint160(address(this)))), "hook: source agent");
        assertEq(message.length, 148 + 228 + 64, "exact length our parser expects");

        // destination side: pretend to be Arbitrum; agent = dstAgent
        vm.chainId(42161);
        dst.setRemote(8453, DOMAIN_BASE, address(src));

        vm.mockCall(MESSAGE_TRANSMITTER_V2, abi.encodeWithSelector(IMessageTransmitterV2.receiveMessage.selector), abi.encode(true));
        vm.prank(dstAgent);
        (bytes32 id, uint64 srcChain, address srcAgent) = dst.finalize(abi.encode(message, bytes("")));
        assertEq(id, transferId);
        assertEq(srcChain, 8453);
        assertEq(srcAgent, address(this));

        // a burn from anyone but the registered peer adapter is rejected
        bytes memory tampered = message;
        _write32(tampered, 148 + 100, bytes32(uint256(uint160(makeAddr("impostor")))));
        vm.prank(dstAgent);
        vm.expectRevert(CctpV2Adapter.InvalidMessage.selector);
        dst.finalize(abi.encode(tampered, bytes("")));

        // and nobody but the agent can finalize
        vm.expectRevert(CctpV2Adapter.Unauthorized.selector);
        dst.finalize(abi.encode(message, bytes("")));
    }

    function _messageSent(Vm.Log[] memory logs) internal pure returns (bytes memory message) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == MESSAGE_TRANSMITTER_V2 && logs[i].topics[0] == MESSAGE_SENT) {
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("MessageSent not found");
    }

    function _slice32(bytes memory b, uint256 offset) internal pure returns (bytes32 w) {
        require(offset + 32 <= b.length, "oob");
        assembly {
            w := mload(add(add(b, 32), offset))
        }
    }

    function _write32(bytes memory b, uint256 offset, bytes32 w) internal pure {
        assembly {
            mstore(add(add(b, 32), offset), w)
        }
    }
}
