import * as fs from 'fs';
import { JsonRpcProvider, Contract } from 'ethers';

const ARB_RPC = process.env.ARB_RPC_URL || 'https://arb1.arbitrum.io/rpc';

async function main() {
  const sel = JSON.parse(fs.readFileSync('/tmp/arb-selection.json', 'utf8'));
  const provider = new JsonRpcProvider(ARB_RPC, 42161, { batchMaxCount: 1 });
  console.log('using rpc:', ARB_RPC);

  // 1. Comet: baseToken must be native USDC, and it must have supply caps etc.
  const comet = new Contract(
    sel.comet,
    [
      'function baseToken() view returns (address)',
      'function baseTokenPriceFeed() view returns (address)',
      'function numAssets() view returns (uint8)',
    ],
    provider,
  );
  const baseToken = await comet.baseToken();
  console.log(
    'comet.baseToken == native USDC:',
    baseToken.toLowerCase() === sel.usdc.toLowerCase() ? 'PASS' : 'FAIL',
  );
  console.log('comet.numAssets:', (await comet.numAssets()).toString());

  // 2. Aave pool addresses provider: getPool non-zero
  const aave = new Contract(
    sel.aavePoolAddressesProvider,
    ['function getPool() view returns (address)'],
    provider,
  );
  const pool = await aave.getPool();
  console.log('aave.getPool() non-zero:', pool !== '0x0000000000000000000000000000000000000000' ? 'PASS' : 'FAIL');

  // 3. Morpho vaults: MetaMorpho checks
  const morphoAbi = [
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function asset() view returns (address)',
    'function decimals() view returns (uint8)',
    'function fee() view returns (uint256)',
    'function timelock() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function curator() view returns (address)',
  ];
  for (const { strategy, vaultAddress } of sel.morphoVaults) {
    try {
      const v = new Contract(vaultAddress, morphoAbi, provider);
      const [name, asset, decimals, fee, timelock, totalAssets, curator] =
        await Promise.all([
          v.name(),
          v.asset(),
          v.decimals(),
          v.fee(),
          v.timelock(),
          v.totalAssets(),
          v.curator().catch(() => 'n/a'),
        ]);
      const assetOk = asset.toLowerCase() === sel.usdc.toLowerCase();
      console.log(
        `${strategy}: name="${name}" asset==USDC:${assetOk ? 'PASS' : 'FAIL'} decimals=${decimals} fee=${fee} timelock=${timelock} totalAssets=${totalAssets} curator=${curator}`,
      );
    } catch (e: unknown) {
      console.log(`${strategy}: CHECK FAILED`, e instanceof Error ? e.message.slice(0, 120) : e);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
