import * as dotenv from 'dotenv';
import * as fs from 'fs';
import { Wallet, JsonRpcProvider, Contract, formatUnits } from 'ethers';

dotenv.config();

async function main() {
  const usdcAddr = fs.readFileSync('/tmp/monad-usdc.txt', 'utf8').trim();
  const provider = new JsonRpcProvider('https://rpc.monad.xyz', 143);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  const usdc = new Contract(
    usdcAddr,
    ['function balanceOf(address) view returns (uint256)'],
    provider,
  );
  const [bal, mon] = await Promise.all([
    usdc.balanceOf(wallet.address),
    provider.getBalance(wallet.address),
  ]);
  console.log('USDC on Monad:', formatUnits(bal, 6));
  console.log('MON:', formatUnits(mon, 18));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
