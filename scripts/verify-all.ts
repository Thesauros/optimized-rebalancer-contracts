import { run } from 'hardhat';
import * as fs from 'fs';
import * as dotenv from 'dotenv';
import { Wallet } from 'ethers';

dotenv.config();

const dep = (name: string): string =>
  JSON.parse(fs.readFileSync(`deployments/base/${name}.json`, 'utf8')).address;

const deployer = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!).address;
const treasury = process.env.TREASURY_ADDRESS!;
const timelockDelay = Number(process.env.TIMELOCK_DELAY || '1800');

async function verify(address: string, args: unknown[], label: string) {
  try {
    await run('verify:verify', { address, constructorArguments: args });
    console.log(`${label}: VERIFIED`);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.toLowerCase().includes('already verified')) {
      console.log(`${label}: already verified`);
    } else {
      console.log(`${label}: FAILED - ${msg.slice(0, 200)}`);
    }
  }
}

async function main() {
  const morphoVaultArgs: Record<string, string> = {
    SteakhouseHighYieldMorphoProvider:
      '0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F',
    SteakhousePrimeMorphoProvider: '0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2',
    GauntletCoreMorphoProvider: '0xc0c5689e6f4D256E861F65465b691aeEcC0dEb12',
  };

  await verify(dep('ProviderManager'), [deployer], 'ProviderManager');
  await verify(
    dep('CompoundV3Provider'),
    [dep('ProviderManager')],
    'CompoundV3Provider',
  );
  await verify(
    dep('AaveV3Provider'),
    ['0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D'],
    'AaveV3Provider',
  );
  for (const [name, vaultAddress] of Object.entries(morphoVaultArgs)) {
    await verify(dep(name), [vaultAddress], name);
  }
  await verify(dep('Timelock'), [deployer, timelockDelay], 'Timelock');
  await verify(dep('USDCRebalancerImplementation'), [], 'Implementation');
  await verify(
    dep('USDCRebalancerProxy'),
    [dep('USDCRebalancerImplementation'), treasury, '0x'],
    'Proxy',
  );
  console.log('VERIFY_ALL_DONE');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
