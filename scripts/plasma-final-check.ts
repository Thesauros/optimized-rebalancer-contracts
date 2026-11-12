import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';

dotenv.config();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function isVerified(address: string): Promise<string> {
  const url = `https://api.etherscan.io/v2/api?chainid=9745&module=contract&action=getsourcecode&address=${address}&apikey=${process.env.ETHERSCAN_API_KEY}`;
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
    .readdirSync('deployments/plasma')
    .filter((f) => f.endsWith('.json'));

  console.log('--- verification status (live, throttled) ---');
  for (const f of names) {
    const j = JSON.parse(fs.readFileSync(`deployments/plasma/${f}`, 'utf8'));
    console.log(`${f.replace('.json', '')}: ${await isVerified(j.address)}`);
    await sleep(1200);
  }

  console.log('--- vault state (live from chain) ---');
  const proxy = JSON.parse(
    fs.readFileSync('deployments/plasma/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const asset = JSON.parse(
    fs.readFileSync('deployments/plasma/AaveV3Provider.json', 'utf8'),
  );
  void asset;

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
    'function decimals() view returns (uint8)',
  ];
  const vault = new ethers.Contract(proxy, abi, ethers.provider);

  const proxyRecord = JSON.parse(
    fs.readFileSync('deployments/plasma/USDCRebalancerProxy.json', 'utf8'),
  );
  void proxyRecord;
  const constantsSrc = fs.readFileSync('utils/constants.ts', 'utf8');
  const usdt0Match = constantsSrc.match(/9745:\s*\{\s*asset:\s*'([^']+)'/);
  const usdt0Addr = usdt0Match![1];
  const usdt0 = new ethers.Contract(usdt0Addr, abi, ethers.provider);

  const [
    name,
    symbol,
    supply,
    assets,
    providers,
    minAssets,
    timelock,
    treasury,
    usdt0Balance,
  ] = await Promise.all([
    vault.name(),
    vault.symbol(),
    vault.totalSupply(),
    vault.totalAssets(),
    vault.getProviders(),
    vault.getMinAssets(),
    vault.getTimelock(),
    vault.getTreasury(),
    usdt0.balanceOf(deployer.address),
  ]);
  const recordedTimelock = JSON.parse(
    fs.readFileSync('deployments/plasma/Timelock.json', 'utf8'),
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
  console.log('deployer USDT0 remaining:', usdt0Balance.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
