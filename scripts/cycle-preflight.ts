import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, Contract, formatUnits } from 'ethers';
import * as fs from 'fs';

dotenv.config();

const NETWORKS: Record<string, { url: string; native: string }> = {
  base: {
    url:
      process.env.BASE_RPC_URL ??
      `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_PROJECT_ID}`,
    native: 'ETH',
  },
  arbitrum: {
    url:
      process.env.ARBITRUM_RPC_URL &&
      !process.env.ARBITRUM_RPC_URL.includes('alchemy.com')
        ? process.env.ARBITRUM_RPC_URL
        : 'https://arb1.arbitrum.io/rpc',
    native: 'ETH',
  },
  plasma: { url: process.env.PLASMA_RPC_URL ?? 'https://rpc.plasma.to', native: 'XPL' },
  monad: { url: process.env.MONAD_RPC_URL ?? 'https://rpc.monad.xyz', native: 'MON' },
};

const VAULT_ABI = [
  'function asset() view returns (address)',
  'function balanceOf(address) view returns (uint256)',
  'function maxDeposit(address) view returns (uint256)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function paused() view returns (bool)',
];
const TOKEN_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
];

async function main() {
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!);
  console.log('deployer:', wallet.address);
  let problems = 0;

  for (const [name, cfg] of Object.entries(NETWORKS)) {
    console.log(`\n=== ${name} (${cfg.url}) ===`);
    const provider = new JsonRpcProvider(cfg.url);
    const proxyAddr = JSON.parse(
      fs.readFileSync(`deployments/${name}/USDCRebalancerProxy.json`, 'utf8'),
    ).address;
    const vault = new Contract(proxyAddr, VAULT_ABI, provider);

    const [nativeBal, assetAddr] = await Promise.all([
      provider.getBalance(wallet.address),
      vault.asset(),
    ]);
    const token = new Contract(assetAddr, TOKEN_ABI, provider);
    const [tokenBal, decimals, symbol, shares, maxDep, totalAssets, totalSupply] =
      await Promise.all([
        token.balanceOf(wallet.address),
        token.decimals(),
        token.symbol().catch(() => '???'),
        vault.balanceOf(wallet.address),
        vault.maxDeposit(wallet.address),
        vault.totalAssets(),
        vault.totalSupply(),
      ]);
    let paused = 'n/a';
    try {
      paused = String(await vault.paused());
    } catch {
      /* no paused() on this vault */
    }

    const amt = 10n * 10n ** BigInt(decimals);
    console.log(`vault   ${proxyAddr}`);
    console.log(`asset   ${symbol} ${assetAddr} (dec ${decimals})`);
    console.log(
      `native  ${formatUnits(nativeBal, 18)} ${cfg.native} | token ${formatUnits(tokenBal, decimals)} | need ${formatUnits(amt, decimals)}`,
    );
    console.log(
      `shares  ${shares} | maxDeposit ${formatUnits(maxDep, decimals)} | paused ${paused}`,
    );
    console.log(
      `vault totalAssets ${formatUnits(totalAssets, decimals)} | totalSupply ${totalSupply}`,
    );

    if (nativeBal === 0n) {
      console.log('!! NO GAS');
      problems++;
    }
    if (tokenBal < amt) {
      console.log('!! INSUFFICIENT TOKEN BALANCE');
      problems++;
    }
    if (maxDep < amt) {
      console.log('!! MAX DEPOSIT TOO LOW');
      problems++;
    }
    if (paused === 'true') {
      console.log('!! VAULT PAUSED');
      problems++;
    }
  }

  console.log(problems === 0 ? '\nPREFLIGHT_OK' : `\nPREFLIGHT_PROBLEMS=${problems}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
