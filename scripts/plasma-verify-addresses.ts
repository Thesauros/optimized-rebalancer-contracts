import * as dotenv from 'dotenv';
import * as fs from 'fs';
import { JsonRpcProvider, Contract } from 'ethers';

dotenv.config();

const PLASMA_RPC = 'https://rpc.plasma.to';
const AAVE_PROVIDER_CANDIDATE = '0x061D8e131F26512348ee5FA42e2DF1bA9d6505E9';
const AAVE_POOL_EXPECTED = '0x925a2A7214Ed92428B5b1B090F80b25700095e12';

async function main() {
  const provider = new JsonRpcProvider(PLASMA_RPC);

  const usdt0Addr = fs.readFileSync('/tmp/plasma-usdt0.txt', 'utf8').trim();
  const usdt0 = new Contract(
    usdt0Addr,
    [
      'function symbol() view returns (string)',
      'function name() view returns (string)',
      'function decimals() view returns (uint8)',
      'function totalSupply() view returns (uint256)',
    ],
    provider,
  );
  const [symbol, name, decimals, supply] = await Promise.all([
    usdt0.symbol(),
    usdt0.name(),
    usdt0.decimals(),
    usdt0.totalSupply(),
  ]);
  console.log(
    `USDT0 candidate: symbol=${symbol} name="${name}" decimals=${decimals} totalSupply=${supply}`,
  );

  const aave = new Contract(
    AAVE_PROVIDER_CANDIDATE,
    ['function getPool() view returns (address)'],
    provider,
  );
  const pool = await aave.getPool();
  console.log(
    'aave getPool() == expected pool:',
    pool.toLowerCase() === AAVE_POOL_EXPECTED.toLowerCase(),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
