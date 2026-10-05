// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCTPMeshBridgeAdapter} from "../../contracts/crosschain/bridges/CCTPMeshBridgeAdapter.sol";

/// @notice Phase 3: Deploy CCTPMeshBridgeAdapter on Base (burns USDC to Arbitrum).
///         Run: forge script scripts/deploy/phase3-adapter-base.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
contract Phase3AdapterBase is Script {
    address constant TIMELOCK = 0xb2b1A0c173549A498859822f20Da68be1bEA593D;
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint32 constant ARB_DOMAIN = 3;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address relayArb = vm.envAddress("RELAY_ARB");

        console.log("=== Phase 3: Base Adapter ===");
        console.log("Governance (Timelock):", TIMELOCK);
        console.log("CCTP TokenMessenger:", CCTP_TOKEN_MESSENGER);
        console.log("Dest domain (Arbitrum):", ARB_DOMAIN);
        console.log("Dest relay peer:", relayArb);

        require(relayArb.code.length > 0, "Arbitrum relay not found");

        bytes32 relayPeer = bytes32(uint256(uint160(relayArb)));

        vm.startBroadcast(pk);

        CCTPMeshBridgeAdapter adapter = new CCTPMeshBridgeAdapter(
            TIMELOCK,
            CCTP_TOKEN_MESSENGER,
            ARB_DOMAIN,
            relayPeer
        );
        console.log("CCTPMeshBridgeAdapter:", address(adapter));

        require(adapter.governance() == TIMELOCK);
        require(adapter.destinationDomain() == ARB_DOMAIN);
        require(adapter.relayPeer() == relayPeer);

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 3 Base DONE");
        console.log("ADAPTER_BASE=%s", address(adapter));
    }
}
