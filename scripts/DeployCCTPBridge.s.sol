// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {CCTPMeshBridgeAdapter} from "../contracts/crosschain/bridges/CCTPMeshBridgeAdapter.sol";
import {CCTPRelayReceiver} from "../contracts/crosschain/bridges/CCTPRelayReceiver.sol";

/// @title DeployCCTPBridge
/// @notice Deploys CCTP bridge adapter + relay receiver on each chain.
///
///         Base (source, domain 6):
///           - CCTPMeshBridgeAdapter (burns USDC to Arbitrum)
///           - CCTPRelayReceiver MODE_NODE (receives returns from Arbitrum, delivers to MeshNode)
///
///         Arbitrum (destination, domain 3):
///           - CCTPMeshBridgeAdapter (burns USDC to Base)
///           - CCTPRelayReceiver MODE_CUSTODIAN (receives from Base, delivers to MeshCustodian)
///
/// Usage:
///   # On Base:
///   forge script scripts/DeployCCTPBridge.s.sol \
///     --rpc-url $BASE_RPC_URL --broadcast --verify
///
///   # On Arbitrum:
///   forge script scripts/DeployCCTPBridge.s.sol \
///     --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
///
/// Environment variables:
///   GOVERNANCE          — Timelock address (governance for adapter + relay)
///   RELAY_KEEPER        — Keeper address authorized to call relay.deliver()
///   TARGET_CONTRACT     — MeshNode (Base) or MeshCustodian (Arbitrum) address
///   CCTP_TOKEN_MESSENGER — CCTP V2 TokenMessenger (0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d)
///   CCTP_MSG_TRANSMITTER — CCTP V2 MessageTransmitter (0x81D40F21F12A8F0E3252Bccb954D722d4c464B64)
///   DEST_DOMAIN         — Destination CCTP domain (3 for Arbitrum, 6 for Base)
///   DEST_RELAY_PEER     — Relay receiver address on destination chain (as bytes32)
///   RELAY_MODE          — 0 = MODE_CUSTODIAN (Arbitrum), 1 = MODE_NODE (Base)
///   ASSET               — USDC address on this chain
contract DeployCCTPBridge is Script {
    // CCTP V2 mainnet addresses (same on all chains)
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant CCTP_MSG_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address governance = vm.envAddress("GOVERNANCE");
        address relayKeeper = vm.envAddress("RELAY_KEEPER");
        address target = vm.envAddress("TARGET_CONTRACT");
        uint32 destDomain = uint32(vm.envUint("DEST_DOMAIN"));
        bytes32 destRelayPeer = vm.envBytes32("DEST_RELAY_PEER");
        uint8 relayMode = uint8(vm.envUint("RELAY_MODE"));
        address asset = vm.envAddress("ASSET");

        console.log("=== Deploy CCTP Bridge ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Governance:", governance);
        console.log("Target:", target);
        console.log("Dest domain:", destDomain);
        console.log("Relay mode:", relayMode);
        console.log("");

        vm.startBroadcast(deployerKey);

        // Deploy relay receiver
        console.log("Deploying CCTPRelayReceiver...");
        CCTPRelayReceiver relay = new CCTPRelayReceiver(
            governance,
            CCTP_MSG_TRANSMITTER,
            asset,
            target,
            relayMode,
            relayKeeper
        );
        console.log("CCTPRelayReceiver:", address(relay));

        // Deploy bridge adapter
        console.log("Deploying CCTPMeshBridgeAdapter...");
        CCTPMeshBridgeAdapter adapter = new CCTPMeshBridgeAdapter(
            governance,
            CCTP_TOKEN_MESSENGER,
            destDomain,
            destRelayPeer
        );
        console.log("CCTPMeshBridgeAdapter:", address(adapter));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Relay:", address(relay));
        console.log("Adapter:", address(adapter));
        console.log("");
        console.log("Post-deploy steps:");
        console.log("1. On MeshNode: addRoute(routeId, adapterAddr, destChainId, custodianPeer, maxInFlight, 0)");
        console.log("2. On MeshCustodian: trustAdapter(relayAddr, true)");
        console.log("3. On MeshCustodian: trustAdapter(adapterAddr, true)");
        console.log("4. Start relay keeper: npx hardhat run scripts/cctp-relay-keeper.ts");
    }
}
