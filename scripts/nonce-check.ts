import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider } from 'ethers';

dotenv.config();

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  const urls: [string, string][] = [
    ['RPC_URL', process.env.RPC_URL!],
    ['public', 'https://mainnet.base.org'],
  ];
  for (const [label, url] of urls) {
    if (!url) continue;
    const provider = new JsonRpcProvider(url);
    const [latest, pending, feeData] = await Promise.all([
      provider.getTransactionCount(wallet.address, 'latest'),
      provider.getTransactionCount(wallet.address, 'pending'),
      provider.getFeeData(),
    ]);
    console.log(
      `${label}: latest=${latest} pending=${pending} gasPrice=${feeData.gasPrice} maxFee=${feeData.maxFeePerGas} priority=${feeData.maxPriorityFeePerGas}`,
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
