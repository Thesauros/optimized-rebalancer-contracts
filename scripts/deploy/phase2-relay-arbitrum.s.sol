// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCTPRelayReceiver} from "../../contracts/crosschain/bridges/CCTPRelayReceiver.sol";

/// @notice Phase 2: Deploy CCTPRelayReceiver on Arbitrum (MODE_CUSTODIAN — receives from Base).
///         Run: forge script scripts/deploy/phase2-relay-arbitrum.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
contract Phase2RelayArbitrum is Script {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant TIMELOCK = 0x694C38fb29fd14dECbBe11A15009aC7e728A686D;
    address constant CCTP_MSG_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address custodianAddr = vm.envAddress("MESH_CUSTODIAN_ARB");
        address relayKeeper = vm.envAddress("RELAY_KEEPER");

        console.log("=== Phase 2: Arbitrum Relay ===");
        console.log("MeshCustodian (target):", custodianAddr);
        console.log("Relay keeper:", relayKeeper);
        console.log("Mode: CUSTODIAN (0) — receives from Base");

        require(custodianAddr.code.length > 0, "MeshCustodian not found");

        vm.startBroadcast(pk);

        CCTPRelayReceiver relay = new CCTPRelayReceiver(
            TIMELOCK,
            CCTP_MSG_TRANSMITTER,
            USDC,
            custodianAddr,
            0, // MODE_CUSTODIAN
            relayKeeper
        );
        console.log("CCTPRelayReceiver:", address(relay));

        require(relay.target() == custodianAddr);
        require(relay.mode() == 0);
        require(relay.keeper() == relayKeeper);

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 2 Arbitrum DONE");
        console.log("RELAY_ARB=%s", address(relay));
    }
}
