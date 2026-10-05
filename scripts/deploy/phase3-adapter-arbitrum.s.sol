// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCTPMeshBridgeAdapter} from "../../contracts/crosschain/bridges/CCTPMeshBridgeAdapter.sol";

/// @notice Phase 3: Deploy CCTPMeshBridgeAdapter on Arbitrum (burns USDC to Base).
///         Run: forge script scripts/deploy/phase3-adapter-arbitrum.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
contract Phase3AdapterArbitrum is Script {
    address constant TIMELOCK = 0x694C38fb29fd14dECbBe11A15009aC7e728A686D;
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint32 constant BASE_DOMAIN = 6;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address relayBase = vm.envAddress("RELAY_BASE");

        console.log("=== Phase 3: Arbitrum Adapter ===");
        console.log("Governance (Timelock):", TIMELOCK);
        console.log("CCTP TokenMessenger:", CCTP_TOKEN_MESSENGER);
        console.log("Dest domain (Base):", BASE_DOMAIN);
        console.log("Dest relay peer:", relayBase);

        require(relayBase.code.length > 0, "Base relay not found");

        bytes32 relayPeer = bytes32(uint256(uint160(relayBase)));

        vm.startBroadcast(pk);

        CCTPMeshBridgeAdapter adapter = new CCTPMeshBridgeAdapter(
            TIMELOCK,
            CCTP_TOKEN_MESSENGER,
            BASE_DOMAIN,
            relayPeer
        );
        console.log("CCTPMeshBridgeAdapter:", address(adapter));

        require(adapter.governance() == TIMELOCK);
        require(adapter.destinationDomain() == BASE_DOMAIN);
        require(adapter.relayPeer() == relayPeer);

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 3 Arbitrum DONE");
        console.log("ADAPTER_ARB=%s", address(adapter));
    }
}
