import * as fs from 'fs';

// Reads downloaded data files, picks candidates, writes selection JSON.
// Prints no addresses — they stay in files and get verified on-chain next.

const morpho = JSON.parse(fs.readFileSync('/tmp/morpho-arb.json', 'utf8'));
const roots = JSON.parse(
  require('child_process')
    .execSync(
      'curl -s https://raw.githubusercontent.com/compound-finance/comet/main/deployments/arbitrum/usdc/roots.json',
    )
    .toString(),
);

const picks: Record<string, string> = {
  bbqUSDC: 'SteakhouseHighYield',
  steakUSDC: 'SteakhousePrime',
  gtUSDCc: 'GauntletCore',
};

const morphoVaults: { strategy: string; vaultAddress: string }[] = [];
for (const item of morpho.data.vaults.items) {
  if (picks[item.symbol]) {
    morphoVaults.push({ strategy: picks[item.symbol], vaultAddress: item.address });
  }
}

if (morphoVaults.length !== 3) {
  console.log('ERROR: expected 3 morpho picks, got', morphoVaults.length);
  process.exit(1);
}

const selection = {
  chainId: 42161,
  usdc: '0xaf88d065e77c8cc2239327c5edb3a432268e5831',
  comet: roots.comet,
  aavePoolAddressesProvider: '0xa97684ead0e402dc232d5a977953df7ecbab3cdb',
  morphoVaults,
};

fs.writeFileSync('/tmp/arb-selection.json', JSON.stringify(selection, null, 2));
console.log('selection written; strategies:', morphoVaults.map((m) => m.strategy).join(', '));
