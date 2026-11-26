import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';

dotenv.config();

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

async function isVerified(address: string): Promise<string> {
  const url = `https://api.etherscan.io/v2/api?chainid=8453&module=contract&action=getsourcecode&address=${address}&apikey=${process.env.ETHERSCAN_API_KEY}`;
  const res = await fetch(url);
  const json = await res.json();
  const entry = json.result?.[0];
  if (!entry) return 'UNKNOWN';
  return entry.ABI && entry.ABI !== 'Contract source code not verified'
    ? 'VERIFIED'
    : 'NOT VERIFIED';
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const names = fs
    .readdirSync('deployments/base')
    .filter((f) => f.endsWith('.json'));

  console.log('--- verification status (live from Etherscan API) ---');
  for (const f of names) {
    const j = JSON.parse(fs.readFileSync(`deployments/base/${f}`, 'utf8'));
    console.log(`${f.replace('.json', '')}: ${await isVerified(j.address)}`);
  }

  console.log('--- vault state (live from chain) ---');
  const proxy = JSON.parse(
    fs.readFileSync('deployments/base/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const abi = [
    'function totalSupply() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
  ];
  const vault = new ethers.Contract(proxy, abi, ethers.provider);
  const usdc = new ethers.Contract(USDC, abi, ethers.provider);
  const [supply, assets, usdcBalance] = await Promise.all([
    vault.totalSupply(),
    vault.totalAssets(),
    usdc.balanceOf(deployer.address),
  ]);
  console.log('totalSupply (shares):', supply.toString());
  console.log('totalAssets (USDC, 6 dec):', assets.toString());
  console.log('deployer USDC remaining:', usdcBalance.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
