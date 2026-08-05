import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';

dotenv.config();

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployment = JSON.parse(
    fs.readFileSync('deployments/base/USDCRebalancerProxy.json', 'utf8'),
  );

  const abi = [
    'function totalSupply() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function getTimelock() view returns (address)',
    'function getTreasury() view returns (address)',
    'function getProviders() view returns (address[])',
    'function getMinAssets() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
  ];
  const vault = new ethers.Contract(deployment.address, abi, ethers.provider);
  const usdc = new ethers.Contract(USDC, abi, ethers.provider);

  try {
    const [supply, assets, name, symbol, providers, minAssets, deployerShares] =
      await Promise.all([
        vault.totalSupply(),
        vault.totalAssets(),
        vault.name(),
        vault.symbol(),
        vault.getProviders(),
        vault.getMinAssets(),
        vault.balanceOf(deployer.address),
      ]);
    console.log('INITIALIZED: yes');
    console.log('name/symbol:', name, '/', symbol);
    console.log('totalSupply:', supply.toString());
    console.log('totalAssets:', assets.toString());
    console.log('providers:', providers.length);
    console.log('minAssets:', minAssets.toString());
    console.log('deployer shares:', deployerShares.toString());
  } catch (e: any) {
    console.log('INITIALIZED: no (getter reverted)');
  }

  const usdcBalance = await usdc.balanceOf(deployer.address);
  console.log('deployer USDC now:', usdcBalance.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
