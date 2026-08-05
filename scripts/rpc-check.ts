import * as dotenv from 'dotenv';
import { JsonRpcProvider } from 'ethers';

dotenv.config();

async function probe(label: string, url: string | undefined) {
  if (!url) {
    console.log(`${label}: NOT_SET`);
    return;
  }
  try {
    const provider = new JsonRpcProvider(url);
    const network = await provider.getNetwork();
    console.log(`${label}: OK chainId=${network.chainId}`);
  } catch {
    console.log(`${label}: FAILS`);
  }
}

async function main() {
  await probe('BASE_RPC_URL(env)', process.env.BASE_RPC_URL);
  await probe('public mainnet.base.org', 'https://mainnet.base.org');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
