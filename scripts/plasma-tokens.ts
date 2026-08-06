import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, Contract, formatUnits } from 'ethers';

dotenv.config();

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  const url = `https://api.etherscan.io/v2/api?chainid=9745&module=account&action=tokentx&address=${wallet.address}&startblock=0&endblock=999999999&sort=desc&apikey=${process.env.ETHERSCAN_API_KEY}`;
  const res = await fetch(url);
  const json = await res.json();
  if (json.status !== '1') {
    console.log('api:', json.message, String(json.result).slice(0, 200));
    return;
  }
  const seen = new Map<string, { symbol: string; decimals: number }>();
  for (const tx of json.result as Array<Record<string, string>>) {
    if (!seen.has(tx.contractAddress.toLowerCase())) {
      seen.set(tx.contractAddress.toLowerCase(), {
        symbol: tx.tokenSymbol,
        decimals: Number(tx.tokenDecimal),
      });
    }
  }
  console.log('tokens seen in deployer history:');
  const provider = new JsonRpcProvider('https://rpc.plasma.to');
  let usdt0Addr: string | null = null;
  for (const [addr, meta] of seen) {
    const usdt0 = /^usdt0$/i.test(meta.symbol);
    const token = new Contract(
      addr,
      ['function balanceOf(address) view returns (uint256)'],
      provider,
    );
    let bal = 'ERR';
    try {
      bal = formatUnits(await token.balanceOf(wallet.address), meta.decimals);
    } catch {
      /* ignore */
    }
    if (usdt0 && usdt0Addr === null && bal !== 'ERR' && bal !== '0.0') {
      usdt0Addr = addr;
    }
    console.log(
      `${usdt0 ? '>>> ' : '    '}${meta.symbol} (dec ${meta.decimals}) balance=${bal} addr=${addr}`,
    );
  }
  if (usdt0Addr) {
    const fs = await import('fs');
    fs.writeFileSync('/tmp/plasma-usdt0.txt', usdt0Addr);
    console.log('USDT0 address saved to /tmp/plasma-usdt0.txt');
  } else {
    console.log('USDT0 address NOT found');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
