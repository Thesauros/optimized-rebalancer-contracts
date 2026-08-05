import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider } from 'ethers';

dotenv.config();

async function main() {
  const url = process.env.BASE_RPC_URL ?? 'https://mainnet.base.org';
  const provider = new JsonRpcProvider(url);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!).connect(provider);

  const t0 = Date.now();
  const tx = await wallet.sendTransaction({ to: wallet.address, value: 0n });
  console.log('submitted, waiting for receipt...');

  const receipt = await Promise.race([
    tx.wait(1),
    new Promise<never>((_, rej) =>
      setTimeout(() => rej(new Error('TIMEOUT_60S')), 60_000),
    ),
  ]);
  console.log(
    'CONFIRMED in',
    ((Date.now() - t0) / 1000).toFixed(1),
    's, block',
    receipt!.blockNumber,
  );
}

main().catch((e) => {
  console.error('RESULT:', e.message);
  process.exit(1);
});
