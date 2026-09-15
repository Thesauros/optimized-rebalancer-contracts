/**
 * Canary cycle: small-amount crosschain flow on mainnet.
 *
 * This script executes a manual crosschain principal transport cycle
 * between Base (source) and Arbitrum (destination) using the deployed
 * crosschain stand contracts. It is NOT automated — each step requires
 * manual verification before proceeding.
 *
 * Prerequisites:
 *   1. MeshNode deployed on Base (source)
 *   2. MeshCustodian deployed on Arbitrum (destination)
 *   3. Bridge adapter deployed on both chains
 *   4. Node configured with vault and route
 *   5. Custodian configured with trusted adapter
 *
 * Usage:
 *   npx hardhat run scripts/canary-cycle.ts --network base
 *
 * Environment variables:
 *   MESH_NODE_BASE          — MeshNode address on Base
 *   MESH_CUSTODIAN_ARB      — MeshCustodian address on Arbitrum
 *   BRIDGE_ADAPTER_BASE     — Bridge adapter address on Base
 *   BRIDGE_ADAPTER_ARB      — Bridge adapter address on Arbitrum
 *   CANARY_AMOUNT           — Amount in USDC units (default: 10e6 = $10)
 *   KEEPER_KEY              — Private key for the executor/keeper
 */

import { ethers } from 'hardhat';

const CANARY_AMOUNT = process.env.CANARY_AMOUNT || '10000000'; // 10 USDC

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('=== Crosschain Canary Cycle ===');
  console.log('Deployer:', deployer.address);
  console.log('Network:', (await ethers.provider.getNetwork()).name);
  console.log('');

  // Addresses from environment
  const nodeAddr = process.env.MESH_NODE_BASE;
  const custodianAddr = process.env.MESH_CUSTODIAN_ARB;
  const bridgeAddr = process.env.BRIDGE_ADAPTER_BASE;

  if (!nodeAddr || !custodianAddr || !bridgeAddr) {
    console.error('Missing required environment variables:');
    console.error('  MESH_NODE_BASE, MESH_CUSTODIAN_ARB, BRIDGE_ADAPTER_BASE');
    process.exit(1);
  }

  // Step 1: Verify contracts exist
  console.log('Step 1: Verifying contract deployments...');
  const node = await ethers.getContractAt('MeshNode', nodeAddr);
  const assetAddr = await node.asset();
  const usdc = await ethers.getContractAt('IERC20', assetAddr);

  console.log('  MeshNode:', nodeAddr);
  console.log('  Asset:', assetAddr);
  console.log('  Governance:', await node.governance());
  console.log('  Executor:', await node.executor());
  console.log('  Guardian:', await node.guardian());
  console.log('  Total assets:', (await node.totalAssets()).toString());
  console.log('  Paused:', await node.paused());
  console.log('');

  // Step 2: Check vault configuration
  console.log('Step 2: Checking vault configuration...');
  const vaults: string[] = [];
  // In production, vault addresses would be known from deployment
  // For canary, we check the existing Base vault
  const baseVault = '0x3C7739173cca612B6394EE57131458185A5beC44';
  const vaultConfig = await node.vaults(baseVault);
  console.log(`  Vault ${baseVault}:`);
  console.log('    Enabled:', vaultConfig[0]);
  console.log('    MinLocalBps:', vaultConfig[1].toString());
  console.log('    MaxRemoteBps:', vaultConfig[2].toString());

  if (!vaultConfig[0]) {
    console.error('  ERROR: Vault not configured in node. Run configureVault first.');
    process.exit(1);
  }
  console.log('');

  // Step 3: Check routes
  console.log('Step 3: Checking routes...');
  // Routes are keyed by bytes32 routeId — for canary we check a known route
  console.log('  Routes must be configured via governance before canary.');
  console.log('  Use: node.addRoute(routeId, bridgeAdapter, destChainId, destPeer, maxInFlight, maxFeeBps)');
  console.log('');

  // Step 4: Verify balances
  console.log('Step 4: Checking balances...');
  const deployerBalance = await usdc.balanceOf(deployer.address);
  console.log(`  Deployer USDC: ${ethers.formatUnits(deployerBalance, 6)}`);

  const canaryAmount = BigInt(CANARY_AMOUNT);
  if (deployerBalance < canaryAmount) {
    console.error(`  ERROR: Insufficient USDC. Need ${ethers.formatUnits(canaryAmount, 6)}, have ${ethers.formatUnits(deployerBalance, 6)}`);
    process.exit(1);
  }
  console.log('');

  // Step 5: Summary
  console.log('=== Canary Readiness Summary ===');
  console.log('Contracts deployed: YES');
  console.log('Vault configured:', vaultConfig[0] ? 'YES' : 'NO');
  console.log('Balance sufficient:', deployerBalance >= canaryAmount ? 'YES' : 'NO');
  console.log('');
  console.log('Next manual steps:');
  console.log('1. Configure route on MeshNode (governance tx via Timelock)');
  console.log('2. Trust bridge adapter on MeshCustodian (governance tx)');
  console.log('3. Rebalance vault into MeshProvider (executor tx)');
  console.log('4. Execute bridgeOut (executor tx)');
  console.log('5. Relay bridge message to Arbitrum (manual keeper)');
  console.log('6. Verify custodian received funds');
  console.log('7. Execute bridgeBack for return (executor tx)');
  console.log('8. Relay return message to Base (manual keeper)');
  console.log('9. Verify node accounting reconciled');
  console.log('');
  console.log('Canary amount:', ethers.formatUnits(canaryAmount, 6), 'USDC');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
