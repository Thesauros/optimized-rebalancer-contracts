// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MeshNode} from "../../contracts/crosschain/MeshNode.sol";
import {MeshProvider} from "../../contracts/crosschain/MeshProvider.sol";

/// @notice Phase 1: Deploy MeshNode + MeshProvider on Base (source chain).
///         Run: forge script scripts/deploy/phase1-core-base.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
contract Phase1CoreBase is Script {
    // Base mainnet
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TIMELOCK = 0xb2b1A0c173549A498859822f20Da68be1bEA593D;
    address constant EXISTING_VAULT = 0x3C7739173cca612B6394EE57131458185A5beC44;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");

        console.log("=== Phase 1: Base Core ===");
        console.log("Deployer:", deployer);
        console.log("Keeper:", keeper);
        console.log("Guardian:", guardian);
        console.log("Governance (Timelock):", TIMELOCK);
        console.log("USDC:", USDC);

        require(USDC.code.length > 0, "USDC not found");
        require(TIMELOCK.code.length > 0, "Timelock not found");

        vm.startBroadcast(pk);

        MeshNode node = new MeshNode(USDC, TIMELOCK, keeper, guardian);
        console.log("MeshNode:", address(node));

        MeshProvider provider = new MeshProvider(node);
        console.log("MeshProvider:", address(provider));

        // Verify
        require(node.asset() == USDC);
        require(node.governance() == TIMELOCK);
        require(node.executor() == keeper);
        require(node.guardian() == guardian);
        require(address(provider.node()) == address(node));

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 1 Base DONE");
        console.log("MESH_NODE_BASE=%s", address(node));
        console.log("MESH_PROVIDER_BASE=%s", address(provider));
    }
}
