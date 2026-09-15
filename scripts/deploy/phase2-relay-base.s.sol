// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCTPRelayReceiver} from "../../contracts/crosschain/bridges/CCTPRelayReceiver.sol";

/// @notice Phase 2: Deploy CCTPRelayReceiver on Base (MODE_NODE — receives returns from Arbitrum).
///         Run: forge script scripts/deploy/phase2-relay-base.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
contract Phase2RelayBase is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TIMELOCK = 0xb2b1A0c173549A498859822f20Da68be1bEA593D;
    address constant CCTP_MSG_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address nodeAddr = vm.envAddress("MESH_NODE_BASE");
        address relayKeeper = vm.envAddress("RELAY_KEEPER");

        console.log("=== Phase 2: Base Relay ===");
        console.log("MeshNode (target):", nodeAddr);
        console.log("Relay keeper:", relayKeeper);
        console.log("Mode: NODE (1) — receives returns from Arbitrum");

        require(nodeAddr.code.length > 0, "MeshNode not found");

        vm.startBroadcast(pk);

        CCTPRelayReceiver relay = new CCTPRelayReceiver(
            TIMELOCK,
            CCTP_MSG_TRANSMITTER,
            USDC,
            nodeAddr,
            1, // MODE_NODE
            relayKeeper
        );
        console.log("CCTPRelayReceiver:", address(relay));

        require(relay.target() == nodeAddr);
        require(relay.mode() == 1);
        require(relay.keeper() == relayKeeper);

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 2 Base DONE");
        console.log("RELAY_BASE=%s", address(relay));
    }
}
