import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';

dotenv.config();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function isVerified(address: string): Promise<string> {
  const url = `https://api.etherscan.io/v2/api?chainid=143&module=contract&action=getsourcecode&address=${address}&apikey=${process.env.ETHERSCAN_API_KEY}`;
  const res = await fetch(url);
  const json = await res.json();
  if (json.status !== '1' && typeof json.result === 'string') {
    return `API: ${String(json.result).slice(0, 80)}`;
  }
  const entry = json.result?.[0];
  if (!entry) return 'UNKNOWN';
  return entry.ABI && entry.ABI !== 'Contract source code not verified'
    ? 'VERIFIED'
    : 'NOT VERIFIED';
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const names = fs
    .readdirSync('deployments/monad')
    .filter((f) => f.endsWith('.json'));

  console.log('--- verification status (live, throttled) ---');
  for (const f of names) {
    const j = JSON.parse(fs.readFileSync(`deployments/monad/${f}`, 'utf8'));
    console.log(`${f.replace('.json', '')}: ${await isVerified(j.address)}`);
    await sleep(1200);
  }

  console.log('--- vault state (live from chain) ---');
  const proxy = JSON.parse(
    fs.readFileSync('deployments/monad/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const usdcAddr = fs.readFileSync('/tmp/monad-usdc.txt', 'utf8').trim();

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
  const usdc = new ethers.Contract(usdcAddr, abi, ethers.provider);

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
    fs.readFileSync('deployments/monad/Timelock.json', 'utf8'),
  ).address;
  console.log('name/symbol:', name, '/', symbol);
  console.log('totalSupply:', supply.toString());
  console.log('totalAssets:', assets.toString());
  console.log('providers count:', providers.length);
  console.log('minAssets:', minAssets.toString());
  console.log(
    'timelock == recorded Timelock:',
    timelock.toLowerCase() === recordedTimelock.toLowerCase(),
  );
  console.log(
    'treasury == TREASURY_ADDRESS:',
    treasury.toLowerCase() === (process.env.TREASURY_ADDRESS || '').toLowerCase(),
  );
  console.log('deployer USDC remaining:', usdcBalance.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
