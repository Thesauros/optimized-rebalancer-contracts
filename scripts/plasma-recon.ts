import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, formatEther } from 'ethers';

dotenv.config();

async function probeRpc(url: string) {
  try {
    const provider = new JsonRpcProvider(url);
    const [network, block] = await Promise.race([
      Promise.all([provider.getNetwork(), provider.getBlockNumber()]),
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error('timeout')), 20000)),
    ]);
    console.log(`${url}: chainId=${network.chainId} block=${block}`);
    return { provider, network };
  } catch (e: unknown) {
    console.log(`${url}: FAIL -`, e instanceof Error ? e.message.slice(0, 100) : e);
    return null;
  }
}

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  for (const url of [
    'https://rpc.plasma.to',
    'https://plasma.drpc.org',
    'https://9745.rpc.thirdweb.com',
  ]) {
    const r = await probeRpc(url);
    if (!r) continue;
    try {
      const [balance, feeData] = await Promise.all([
        r.provider.getBalance(wallet.address),
        r.provider.getFeeData(),
      ]);
      console.log(`  deployer gas-token balance: ${formatEther(balance)}`);
      console.log(
        `  feeData: gasPrice=${feeData.gasPrice} maxFee=${feeData.maxFeePerGas} priority=${feeData.maxPriorityFeePerGas}`,
      );
    } catch (e: unknown) {
      console.log('  balance check fail:', e instanceof Error ? e.message.slice(0, 100) : e);
    }
    break;
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
