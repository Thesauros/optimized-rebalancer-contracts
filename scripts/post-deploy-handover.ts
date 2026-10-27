/**
 * Post-deploy report and ownership handover for a deployed vault stack.
 *
 * Usage:
 *   npx hardhat run scripts/post-deploy-handover.ts --network mainnet
 *   HANDOVER=1 npx hardhat run scripts/post-deploy-handover.ts --network mainnet
 *
 * At initialize the vault ADMIN_ROLE goes to the treasury, so granting
 * EXECUTOR_ROLE can only be executed from the treasury Safe; this script prints
 * the exact calldata instead of trying to send it. Timelock and ProviderManager
 * are Ownable2Step owned by the deployer, so HANDOVER starts the two-step
 * transfer and the Safe still has to call acceptOwnership().
 */
import hre, { ethers } from 'hardhat';
import fs from 'fs';
import path from 'path';

import { TREASURY_ADDRESS } from '../utils/constants';

const EXECUTOR_TARGET = '0x48aee620254556dfa676d9ceb0B2f2a19B6469c5';
const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');
const ADMIN_ROLE = ethers.ZeroHash;

const OWNABLE_ABI = [
  'function owner() view returns (address)',
  'function pendingOwner() view returns (address)',
  'function transferOwnership(address newOwner)',
  'function acceptOwnership()',
];

const VAULT_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function asset() view returns (address)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function getTimelock() view returns (address)',
  'function getTreasury() view returns (address)',
  'function getManagementFee() view returns (uint96)',
  'function getPerformanceFee() view returns (uint96)',
  'function getMinAssets() view returns (uint256)',
  'function getEntryProvider() view returns (address)',
  'function getProviders() view returns (address[])',
  'function hasRole(bytes32,address) view returns (bool)',
  'function grantRole(bytes32,address)',
];

function readDeployment(name: string): string | null {
  const file = path.join(
    hre.config.paths.deployments,
    hre.network.name,
    `${name}.json`,
  );
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8')).address;
}

async function main() {
  const handover = process.env.HANDOVER === '1';
  const [signer] = await ethers.getSigners();
  const deployer = signer.address;

  const proxyAddress = readDeployment('USDCRebalancerProxy');
  const timelockAddress = readDeployment('Timelock');
  const providerManagerAddress = readDeployment('ProviderManager');
  if (!proxyAddress) {
    throw new Error(`no USDCRebalancerProxy record for ${hre.network.name}`);
  }

  console.log(`network:  ${hre.network.name} (chainId ${(await ethers.provider.getNetwork()).chainId})`);
  console.log(`deployer: ${deployer}`);
  console.log(`treasury: ${TREASURY_ADDRESS}`);
  console.log(`mode:     ${handover ? 'HANDOVER' : 'report only'}`);
  console.log('');

  const vault = await ethers.getContractAt(VAULT_ABI, proxyAddress);
  const [name, symbol, asset, decimals, totalAssets, totalSupply, timelock, treasury, mgmtFee, perfFee, minAssets, entry, providers] =
    await Promise.all([
      vault.name(),
      vault.symbol(),
      vault.asset(),
      vault.decimals(),
      vault.totalAssets(),
      vault.totalSupply(),
      vault.getTimelock(),
      vault.getTreasury(),
      vault.getManagementFee(),
      vault.getPerformanceFee(),
      vault.getMinAssets(),
      vault.getEntryProvider(),
      vault.getProviders(),
    ]);

  console.log(`=== vault ${proxyAddress} ===`);
  console.log(`  ${name} / ${symbol}  asset=${asset} decimals=${decimals}`);
  console.log(`  totalAssets=${ethers.formatUnits(totalAssets, decimals)}  totalSupply=${ethers.formatUnits(totalSupply, decimals)}`);
  console.log(`  dead shares held by the vault: ${ethers.formatUnits(await vault.balanceOf(proxyAddress), decimals)}`);
  console.log(`  minAssets=${minAssets}  mgmtFee=${mgmtFee}  perfFee=${perfFee}`);
  console.log(`  timelock=${timelock} (record: ${timelockAddress})`);
  console.log(`  treasury=${treasury}`);
  console.log(`  entry provider=${entry}`);
  console.log(`  providers (${providers.length}): ${providers.join(', ')}`);
  console.log(`  treasury has ADMIN_ROLE: ${await vault.hasRole(ADMIN_ROLE, TREASURY_ADDRESS!)}`);
  console.log(`  deployer has ADMIN_ROLE: ${await vault.hasRole(ADMIN_ROLE, deployer)}`);
  console.log(`  executor has EXECUTOR_ROLE: ${await vault.hasRole(EXECUTOR_ROLE, EXECUTOR_TARGET)}`);

  // the proxy admin is the ProxyAdmin the proxy constructor created at nonce 1
  const proxyAdmin = ethers.getCreateAddress({ from: proxyAddress, nonce: 1 });
  const proxyAdminOwner = await new ethers.Contract(
    proxyAdmin,
    OWNABLE_ABI,
    ethers.provider,
  ).owner();
  console.log(`  proxyAdmin=${proxyAdmin} owner=${proxyAdminOwner}`);

  for (const [label, address] of [
    ['Timelock', timelockAddress],
    ['ProviderManager', providerManagerAddress],
  ] as [string, string | null][]) {
    if (!address) {
      console.log(`\n=== ${label}: no record ===`);
      continue;
    }
    const ownable = new ethers.Contract(address, OWNABLE_ABI, signer);
    const owner = await ownable.owner();
    const pending = await ownable.pendingOwner();
    console.log(`\n=== ${label} ${address} ===`);
    console.log(`  owner=${owner}  pendingOwner=${pending}`);

    if (owner.toLowerCase() === TREASURY_ADDRESS!.toLowerCase()) {
      console.log('  already owned by the treasury');
      continue;
    }
    if (owner.toLowerCase() !== deployer.toLowerCase()) {
      console.log('  !! owned by neither the deployer nor the treasury — inspect manually');
      continue;
    }
    if (pending.toLowerCase() === TREASURY_ADDRESS!.toLowerCase()) {
      console.log('  transfer already started; the treasury Safe must call acceptOwnership()');
      continue;
    }
    if (!handover) {
      console.log(`  run with HANDOVER=1 to transferOwnership(${TREASURY_ADDRESS})`);
      continue;
    }

    const tx = await ownable.transferOwnership(TREASURY_ADDRESS!);
    console.log(`  transferOwnership tx: ${tx.hash}`);
    const receipt = await tx.wait(2);
    console.log(`  confirmed in block ${receipt?.blockNumber}, status ${receipt?.status}`);
    console.log(`  pendingOwner now: ${await ownable.pendingOwner()}`);
  }

  console.log('\n=== actions that require the treasury Safe (2/2) ===');
  console.log(`1. vault.grantRole(EXECUTOR_ROLE, ${EXECUTOR_TARGET})`);
  console.log(`   to=${proxyAddress} data=${vault.interface.encodeFunctionData('grantRole', [EXECUTOR_ROLE, EXECUTOR_TARGET])}`);
  for (const [label, address] of [
    ['Timelock', timelockAddress],
    ['ProviderManager', providerManagerAddress],
  ] as [string, string | null][]) {
    if (!address) continue;
    const ownable = new ethers.Contract(address, OWNABLE_ABI, signer);
    if ((await ownable.pendingOwner()).toLowerCase() !== TREASURY_ADDRESS!.toLowerCase()) continue;
    console.log(`2. ${label}.acceptOwnership()`);
    console.log(`   to=${address} data=${ownable.interface.encodeFunctionData('acceptOwnership')}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
