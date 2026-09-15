// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MeshNode} from "../contracts/crosschain/MeshNode.sol";
import {MeshCustodian} from "../contracts/crosschain/MeshCustodian.sol";
import {MeshProvider} from "../contracts/crosschain/MeshProvider.sol";

/// @title DeployCrosschainStand
/// @notice Deploys a SEPARATE crosschain stand on mainnet — does NOT touch existing vaults.
///
///         Base (source): MeshNode + MeshProvider
///         Arbitrum (destination): MeshCustodian
///
///         Roles:
///           governance = deployer (later transferred to Timelock/Safe)
///           executor = KEEPER address (existing keeper EOA)
///           guardian = GUARDIAN address (separate emergency address)
///
/// Usage:
///   forge script scripts/DeployCrosschainStand.s.sol \
///     --rpc-url $BASE_RPC_URL --broadcast --verify
///
///   forge script scripts/DeployCrosschainStand.s.sol \
///     --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
///
/// Environment variables:
///   KEEPER          — executor address (existing keeper EOA)
///   GUARDIAN        — guardian address (emergency pause)
///   ASSET_BASE      — USDC on Base (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
///   ASSET_ARBITRUM  — USDC on Arbitrum (0xaf88d065e77c8cc2239327c5edb3a432268e5831)
///   DEPLOY_SIDE     — "source" or "destination" (which chain we're deploying to)
contract DeployCrosschainStand is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        string memory side = vm.envString("DEPLOY_SIDE");

        console.log("Deployer:", deployer);
        console.log("Keeper:", keeper);
        console.log("Guardian:", guardian);
        console.log("Side:", side);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        if (keccak256(bytes(side)) == keccak256(bytes("source"))) {
            _deploySource(deployer, keeper, guardian);
        } else if (keccak256(bytes(side)) == keccak256(bytes("destination"))) {
            _deployDestination(deployer, keeper, guardian);
        } else {
            revert("DEPLOY_SIDE must be 'source' or 'destination'");
        }

        vm.stopBroadcast();
    }

    /// @notice Deploy MeshNode + MeshProvider on the source chain (Base).
    function _deploySource(address deployer, address keeper, address guardian) internal {
        address asset = vm.envAddress("ASSET_BASE");
        require(asset.code.length > 0, "ASSET_BASE must be a contract");

        console.log("Deploying MeshNode (source)...");
        MeshNode node = new MeshNode(asset, deployer, keeper, guardian);
        console.log("MeshNode:", address(node));

        console.log("Deploying MeshProvider...");
        MeshProvider provider = new MeshProvider(node);
        console.log("MeshProvider:", address(provider));

        // Verify immutable state
        require(node.asset() == asset, "node asset mismatch");
        require(node.governance() == deployer, "node governance mismatch");
        require(node.executor() == keeper, "node executor mismatch");
        require(node.guardian() == guardian, "node guardian mismatch");

        console.log("Source stand deployed successfully");
        console.log("---");
        console.log("Next steps:");
        console.log("1. Configure vault: node.configureVault(vaultAddr, true, 2000, 8000)");
        console.log("2. Add route: node.addRoute(routeId, bridgeAdapter, destChainId, destPeer, maxInFlight, maxFeeBps)");
        console.log("3. Transfer governance to Timelock: node.setGovernance(timelockAddr)");
    }

    /// @notice Deploy MeshCustodian on the destination chain (Arbitrum).
    function _deployDestination(address deployer, address keeper, address guardian) internal {
        address asset = vm.envAddress("ASSET_ARBITRUM");
        require(asset.code.length > 0, "ASSET_ARBITRUM must be a contract");

        console.log("Deploying MeshCustodian (destination)...");
        MeshCustodian custodian = new MeshCustodian(asset, deployer, keeper, guardian);
        console.log("MeshCustodian:", address(custodian));

        // Verify immutable state
        require(custodian.asset() == asset, "custodian asset mismatch");
        require(custodian.governance() == deployer, "custodian governance mismatch");
        require(custodian.executor() == keeper, "custodian executor mismatch");
        require(custodian.guardian() == guardian, "custodian guardian mismatch");

        console.log("Destination stand deployed successfully");
        console.log("---");
        console.log("Next steps:");
        console.log("1. Trust bridge adapter: custodian.trustAdapter(adapterAddr, true)");
        console.log("2. Allow providers: custodian.allowProvider(providerAddr, true)");
        console.log("3. Transfer governance to Timelock: custodian.setGovernance(timelockAddr)");
    }
}
