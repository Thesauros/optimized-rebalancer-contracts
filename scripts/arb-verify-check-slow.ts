import * as dotenv from 'dotenv';
import * as fs from 'fs';

dotenv.config();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function isVerified(address: string): Promise<string> {
  const url = `https://api.etherscan.io/v2/api?chainid=42161&module=contract&action=getsourcecode&address=${address}&apikey=${process.env.ETHERSCAN_API_KEY}`;
  const res = await fetch(url);
  const json = await res.json();
  if (json.status !== '1' && typeof json.result === 'string') {
    return `API: ${json.result}`;
  }
  const entry = json.result?.[0];
  if (!entry) return 'UNKNOWN';
  return entry.ABI && entry.ABI !== 'Contract source code not verified'
    ? 'VERIFIED'
    : 'NOT VERIFIED';
}

async function main() {
  const names = fs
    .readdirSync('deployments/arbitrum')
    .filter((f) => f.endsWith('.json'));
  for (const f of names) {
    const j = JSON.parse(fs.readFileSync(`deployments/arbitrum/${f}`, 'utf8'));
    const status = await isVerified(j.address);
    console.log(`${f.replace('.json', '')}: ${status}`);
    await sleep(1200);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
