import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';

dotenv.config();

const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831';

async function isVerified(address: string): Promise<string> {
  const url = `https://api.etherscan.io/v2/api?chainid=42161&module=contract&action=getsourcecode&address=${address}&apikey=${process.env.ETHERSCAN_API_KEY}`;
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
    .readdirSync('deployments/arbitrum')
    .filter((f) => f.endsWith('.json'));

  console.log('--- verification status (live from Etherscan API) ---');
  for (const f of names) {
    const j = JSON.parse(fs.readFileSync(`deployments/arbitrum/${f}`, 'utf8'));
    console.log(`${f.replace('.json', '')}: ${await isVerified(j.address)}`);
  }

  console.log('--- vault state (live from chain) ---');
  const proxy = JSON.parse(
    fs.readFileSync('deployments/arbitrum/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const abi = [
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function totalSupply() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function getProviders() view returns (address[])',
    'function getMinAssets() view returns (uint256)',
    'function getTimelock() view returns (address)',
    'function getTreasury() view returns (address)',
    'function balanceOf(address) view returns (uint256)',
  ];
  const vault = new ethers.Contract(proxy, abi, ethers.provider);
  const usdc = new ethers.Contract(ARB_USDC, abi, ethers.provider);

  const [
    name,
    symbol,
    supply,
    assets,
    providers,
    minAssets,
    timelock,
    treasury,
    usdcBalance,
  ] = await Promise.all([
    vault.name(),
    vault.symbol(),
    vault.totalSupply(),
    vault.totalAssets(),
    vault.getProviders(),
    vault.getMinAssets(),
    vault.getTimelock(),
    vault.getTreasury(),
    usdc.balanceOf(deployer.address),
  ]);
  const recordedTimelock = JSON.parse(
    fs.readFileSync('deployments/arbitrum/Timelock.json', 'utf8'),
  ).address;
  console.log('name/symbol:', name, '/', symbol);
  console.log('totalSupply:', supply.toString());
  console.log('totalAssets:', assets.toString());
  console.log('providers:', providers.length);
  console.log('minAssets:', minAssets.toString());
  console.log('timelock == recorded Timelock:', timelock.toLowerCase() === recordedTimelock.toLowerCase());
  console.log('treasury == TREASURY_ADDRESS:', treasury.toLowerCase() === (process.env.TREASURY_ADDRESS || '').toLowerCase());
  console.log('deployer USDC remaining:', usdcBalance.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
