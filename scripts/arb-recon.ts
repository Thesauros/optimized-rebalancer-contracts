import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, Contract, formatEther, formatUnits } from 'ethers';

dotenv.config();

const ARB_RPC = 'https://arb1.arbitrum.io/rpc';
const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831'; // native USDC
const ARB_USDC_E = '0xff970a61a04ad10b262bcee1f8907f05d557d3c5'; // bridged USDC.e
const CANDIDATE_COMET = '0x9c4ec768c28520b50860ea7a15bd7213a9ff9856';
const CANDIDATE_AAVE_PROVIDER = '0xa97684ead0e402dc232d5a977953df7ecbab3cdb';

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  const provider = new JsonRpcProvider(ARB_RPC);
  const network = await provider.getNetwork();
  console.log('chainId:', network.chainId.toString());

  const erc20 = ['function balanceOf(address) view returns (uint256)'];
  const usdc = new Contract(ARB_USDC, erc20, provider);

  const [eth, u1, feeData] = await Promise.all([
    provider.getBalance(wallet.address),
    usdc.balanceOf(wallet.address),
    provider.getFeeData(),
  ]);
  console.log('ETH on Arbitrum:', formatEther(eth));
  console.log('native USDC:', formatUnits(u1, 6));
  console.log('gasPrice (gwei):', feeData.gasPrice ? (Number(feeData.gasPrice) / 1e9).toFixed(4) : 'n/a');

  // verify candidate Compound comet: baseToken() must equal native USDC
  const comet = new Contract(
    CANDIDATE_COMET,
    ['function baseToken() view returns (address)'],
    provider,
  );
  try {
    const bt = await comet.baseToken();
    console.log('comet baseToken:', bt, bt.toLowerCase() === ARB_USDC.toLowerCase() ? 'MATCH native USDC' : 'MISMATCH');
  } catch (e: unknown) {
    console.log('comet baseToken() failed:', e instanceof Error ? e.message.slice(0, 100) : e);
  }

  // verify candidate Aave pool addresses provider: getPool()
  const aave = new Contract(
    CANDIDATE_AAVE_PROVIDER,
    ['function getPool() view returns (address)'],
    provider,
  );
  try {
    const pool = await aave.getPool();
    console.log('aave pool:', pool);
  } catch (e: unknown) {
    console.log('aave getPool() failed:', e instanceof Error ? e.message.slice(0, 100) : e);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
