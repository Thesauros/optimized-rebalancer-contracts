import * as dotenv from 'dotenv';
import * as fs from 'fs';
import { JsonRpcProvider, Contract } from 'ethers';

dotenv.config();

const MONAD_RPC = 'https://rpc.monad.xyz';

async function main() {
  const provider = new JsonRpcProvider(MONAD_RPC);

  const usdcAddr = fs.readFileSync('/tmp/monad-usdc.txt', 'utf8').trim();
  const providerAddr = fs.readFileSync('/tmp/monad-aave-provider.txt', 'utf8').trim();

  const usdc = new Contract(
    usdcAddr,
    [
      'function symbol() view returns (string)',
      'function name() view returns (string)',
      'function decimals() view returns (uint8)',
    ],
    provider,
  );
  const [symbol, name, decimals] = await Promise.all([
    usdc.symbol(),
    usdc.name(),
    usdc.decimals(),
  ]);
  console.log(`USDC candidate: symbol=${symbol} name="${name}" decimals=${decimals}`);

  const aave = new Contract(
    providerAddr,
    ['function getPool() view returns (address)'],
    provider,
  );
  const pool = await aave.getPool();
  console.log('aave getPool() non-zero:', pool !== '0x0000000000000000000000000000000000000000');

  // probe Etherscan V2 support for Monad (chainid 143)
  const url = `https://api.etherscan.io/v2/api?chainid=143&module=contract&action=getsourcecode&address=${providerAddr}&apikey=${process.env.ETHERSCAN_API_KEY}`;
  const res = await fetch(url);
  const json = await res.json();
  const entry = Array.isArray(json.result) ? json.result[0] : null;
  console.log(
    'etherscan v2 monad probe:',
    json.status === '1' && entry && entry.ABI && entry.ABI !== 'Contract source code not verified'
      ? 'SUPPORTED (aave provider already verified there)'
      : `status=${json.status} msg=${String(json.message).slice(0, 80)}`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
