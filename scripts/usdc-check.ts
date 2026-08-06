import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, Contract, formatUnits } from 'ethers';

dotenv.config();

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  const urls = [process.env.RPC_URL, 'https://mainnet.base.org'].filter(
    (u): u is string => !!u,
  );
  for (const url of urls) {
    const provider = new JsonRpcProvider(url);
    const usdc = new Contract(
      USDC,
      ['function balanceOf(address) view returns (uint256)'],
      provider,
    );
    const [balance, block] = await Promise.all([
      usdc.balanceOf(wallet.address),
      provider.getBlockNumber(),
    ]);
    console.log(`block=${block} USDC=${formatUnits(balance, 6)} (rpc: ${url === urls[0] ? 'RPC_URL' : 'public'})`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
