import assert from 'node:assert/strict';
import { test } from 'node:test';
import hre from 'hardhat';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';
import deployProvider from '../../deploy/providers/deploy-gauntlet-v2-provider';
import deployVault from '../../deploy/deploy-usdc-vault';

const BASE_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

function fixture(network: string) {
  const calls: string[] = [];
  const deployments: { name: string; options: Record<string, unknown> }[] = [];
  const runtime = {
    network: { name: network },
    ethers: {
      provider: { getNetwork: async () => { calls.push('network'); return { chainId: 8453n }; } },
      getContractAt: async () => {
        calls.push('source');
        return { asset: async () => BASE_USDC };
      },
    },
    getNamedAccounts: async () => { calls.push('signer'); return { deployer: '0x0000000000000000000000000000000000000001' }; },
    deployments: {
      deploy: async (name: string, options: Record<string, unknown>) => {
        calls.push('deploy');
        deployments.push({ name, options });
        return { address: '0x0000000000000000000000000000000000000002' };
      },
    },
  } as unknown as HardhatRuntimeEnvironment;
  return { runtime, calls, deployments };
}

function configureEnv(t: { after(fn: () => void): void }, dryRun?: string) {
  const previousDryRun = process.env.DRY_RUN;
  const previousFork = process.env.FORK_CHAIN_ID;
  if (dryRun === undefined) delete process.env.DRY_RUN;
  else process.env.DRY_RUN = dryRun;
  process.env.FORK_CHAIN_ID = '8453';
  t.after(() => {
    if (previousDryRun === undefined) delete process.env.DRY_RUN;
    else process.env.DRY_RUN = previousDryRun;
    if (previousFork === undefined) delete process.env.FORK_CHAIN_ID;
    else process.env.FORK_CHAIN_ID = previousFork;
  });
}

for (const network of ['mainnet', 'base', 'localhost', 'baseLocal']) {
  test(`provider DRY_RUN rejects ${network} before RPC or signer access`, async (t) => {
    configureEnv(t, '1');
    const { runtime, calls } = fixture(network);
    await assert.rejects(deployProvider(runtime), /DRY_RUN=1.*hardhat/);
    assert.deepEqual(calls, []);
  });
}

test('full-vault DRY_RUN rejects a live network before signer access', async (t) => {
  configureEnv(t, '1');
  const { runtime, calls } = fixture('mainnet');
  // The full-vault script imports ethers directly; even a guard regression must
  // fail locally rather than reaching the configured RPC during this test.
  t.mock.method(hre.ethers.provider, 'getNetwork', async () => {
    calls.push('network');
    throw new Error('unexpected RPC access');
  });
  await assert.rejects(deployVault(runtime), /DRY_RUN=1.*hardhat/);
  assert.deepEqual(calls, []);
});

for (const dryRun of [undefined, '1']) {
  test(`local hardhat provider deployment works with DRY_RUN=${dryRun ?? 'unset'}`, async (t) => {
    configureEnv(t, dryRun);
    const run = t.mock.method(hre, 'run', async () => {});
    const { runtime, deployments } = fixture('hardhat');
    await deployProvider(runtime);
    assert.equal(deployments.length, 1);
    assert.equal(deployments[0].name, 'GauntletPrimeV2MorphoProvider');
    assert.equal(deployments[0].options.contract, 'MorphoV2Provider');
    assert.deepEqual(deployments[0].options.args, ['0x050cE30b927Da55177A4914EC73480238BAD56f0']);
    assert.equal(deployments[0].options.waitConfirmations, 0);
    assert.equal(run.mock.callCount(), 0);
  });
}

test('ordinary live provider deployment retains confirmations and verification', async (t) => {
  configureEnv(t);
  const run = t.mock.method(hre, 'run', async () => {});
  const { runtime, deployments } = fixture('base');
  await deployProvider(runtime);
  assert.equal(deployments.length, 1);
  assert.equal(deployments[0].options.waitConfirmations, 2);
  assert.equal(run.mock.callCount(), 1);
  assert.equal(run.mock.calls[0].arguments[0], 'verify:verify');
});
