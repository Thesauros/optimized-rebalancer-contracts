// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MeshCustodian} from "../../contracts/crosschain/MeshCustodian.sol";

/// @notice Phase 1: Deploy MeshCustodian on Arbitrum (destination chain).
///         Run: forge script scripts/deploy/phase1-core-arbitrum.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
contract Phase1CoreArbitrum is Script {
    // Arbitrum mainnet
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant TIMELOCK = 0x694C38fb29fd14dECbBe11A15009aC7e728A686D;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");

        console.log("=== Phase 1: Arbitrum Core ===");
        console.log("Deployer:", deployer);
        console.log("Keeper:", keeper);
        console.log("Guardian:", guardian);
        console.log("Governance (Timelock):", TIMELOCK);
        console.log("USDC:", USDC);

        require(USDC.code.length > 0, "USDC not found");
        require(TIMELOCK.code.length > 0, "Timelock not found");

        vm.startBroadcast(pk);

        MeshCustodian custodian = new MeshCustodian(USDC, TIMELOCK, keeper, guardian);
        console.log("MeshCustodian:", address(custodian));

        // Verify
        require(custodian.asset() == USDC);
        require(custodian.governance() == TIMELOCK);
        require(custodian.executor() == keeper);
        require(custodian.guardian() == guardian);

        vm.stopBroadcast();

        console.log("");
        console.log("Phase 1 Arbitrum DONE");
        console.log("MESH_CUSTODIAN_ARB=%s", address(custodian));
    }
}
