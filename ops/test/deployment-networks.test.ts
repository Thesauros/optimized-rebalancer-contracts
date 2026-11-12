import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { Interface, Provider, zeroPadValue } from 'ethers';
import { ACCESS, ADAPTER, CHAIN_AGENT, EPOCH_VAULT, OWNABLE, PROVIDER, PROVIDER_MANAGER, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from '../src/abi';
import { checkDeployment } from '../src/checks/deployment';
import { HUB_PARAMS, NETWORKS } from '../../deploy/crosschain/registry';

const manifests = Object.fromEntries(['base', 'arbitrum'].map((key) => {
  const m = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'deployments', key, 'crosschain.json'), 'utf8'));
  // Candidate release manifest, not a claim that the two providers are deployed.
  if (key === 'base') Object.assign(m.contracts, {
    FluidProvider: '0x0000000000000000000000000000000000000f10',
    GauntletPrimeV2MorphoProvider: '0x0000000000000000000000000000000000000a20',
  });
  return [key, { ...m, codehashes: {} }];
}));
const runtime = Object.fromEntries(['base', 'arbitrum'].map((key) => [key, NETWORKS[key]]));
const abi = new Interface([...ACCESS, ...ADAPTER, ...CHAIN_AGENT, ...EPOCH_VAULT, ...OWNABLE, ...PROVIDER, ...PROVIDER_MANAGER, ...STRATEGY, ...TICK_ACCOUNTANT, ...TIMELOCK]);

/** Two-chain deployment fixture. Unexpected third-chain reads are errors. */
function provider(tracked = [8453n, 42161n], wrongFluidSource = false): Provider {
  const m = manifests.base;
  const c = m.contracts;
  const safe = m.deployer;
  const peers = Object.values(runtime);
  const providers = runtime.base.strategy.reusedProviders.map((p) => p.address);
  providers.splice(1, 0, c.CompoundV3Provider);
  providers.push(c.FluidProvider, c.GauntletPrimeV2MorphoProvider);
  const caps = new Map(runtime.base.strategy.reusedProviders.map((p) => [p.address.toLowerCase(), runtime.base.strategy.capsBps[p.label] ?? 0]));
  caps.set(c.CompoundV3Provider.toLowerCase(), runtime.base.strategy.capsBps.CompoundV3);
  caps.set(c.FluidProvider.toLowerCase(), runtime.base.strategy.capsBps.Fluid);
  caps.set(c.GauntletPrimeV2MorphoProvider.toLowerCase(), runtime.base.strategy.capsBps.GauntletPrimeV2Morpho);
  const implementations = new Map(['Strategy', 'ChainAgent', 'TickAccountant', 'EpochVault'].map((name) => [c[name].toLowerCase(), c[`${name}Implementation`]]));
  return {
    getStorage: async (at: string, slot: string) => zeroPadValue(slot.endsWith('bbc') ? implementations.get(at.toLowerCase())! : safe, 32),
    call: async ({ to, data }: { to: string; data: string }) => {
      const tx = abi.parseTransaction({ data })!;
      const peer = tx.name === 'remotes' ? peers.find((entry) => entry.chainId === tx.args[0]) : undefined;
      let value: unknown[];
      switch (tx.name) {
        case 'owner': value = [safe]; break;
        case 'hasRole': case 'isAdapter': case 'isPeer': case 'isAgent': value = [true]; break;
        case 'getTimelock': case 'governance': value = [c.Timelock]; break;
        case 'agent': value = [c.ChainAgent]; break;
        case 'strategy': value = [c.Strategy]; break;
        case 'vault': value = [c.EpochVault]; break;
        case 'accountant': value = [c.TickAccountant]; break;
        case 'hubAgent': value = [c.ChainAgent]; break;
        case 'remotes':
          assert.ok(peer, 'must not read an undeployed peer');
          value = [peer.cctp.domain, manifests[peer.hardhatName].contracts.CctpV2Adapter, true]; break;
        case 'getRoute': {
          const limits = runtime.base.routes['42161'];
          value = [[c.CctpV2Adapter, 42161, manifests.arbitrum.contracts.ChainAgent, limits.maxFeeBps, true, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond, limits.capacity, 0]];
          break;
        }
        case 'getProviders': value = [providers]; break;
        case 'getEntryProvider': value = [providers[0]]; break;
        case 'getProviderCap': value = [caps.get(tx.args[0].toLowerCase())]; break;
        case 'getSource': value = [to.toLowerCase() === c.FluidProvider.toLowerCase()
          ? (wrongFluidSource ? runtime.base.strategy.morphoV2Vault : runtime.base.strategy.fluidFToken)
          : runtime.base.strategy.morphoV2Vault]; break;
        // CompoundV3Provider resolves its Comet through the ProviderManager, so
        // checkDeployment reads it back and compares against the registry. Every
        // call into this fixture checks 'base'.
        case 'getYieldToken': value = [runtime.base.strategy.comet]; break;
        case 'chainIds': value = [tracked]; break;
        case 'getFees': value = [0, 0, 0, safe]; break;
        case 'config': value = [HUB_PARAMS.accountant]; break;
        case 'buckets': value = [{ ...HUB_PARAMS.upBucket, level: 0, updatedAt: 0 }, { ...HUB_PARAMS.downBucket, level: 0, updatedAt: 0 }]; break;
        case 'epochConfig': value = [HUB_PARAMS.epoch]; break;
        case 'limits': value = [HUB_PARAMS.limits]; break;
        case 'maxChainExposure': value = [0]; break;
        default: throw new Error(`unexpected call ${tx.name}`);
      }
      return abi.encodeFunctionResult(tx.name, value);
    },
  } as unknown as Provider;
}

const ids = Object.fromEntries(['safe', 'navUpdater', 'executor', 'guardian'].map((key) => [key, manifests.base.deployer])) as { safe: string; navUpdater: string; executor: string; guardian: string };

test('monitor checks only the deployed runtime peers, without false Ethereum failures', async () => {
  const results = await checkDeployment(provider(), 'base', manifests.base, manifests, ids, runtime);
  assert.deepEqual(results.filter((r) => !r.ok), []);
  assert.ok(results.some((r) => r.label === 'accountant chain set'));
  assert.ok(!results.some((r) => r.label.includes('mainnet')));
});

test('runtime selection cannot hide an extra active accountant chain from monitoring', async () => {
  const results = await checkDeployment(provider([1n, 8453n, 42161n]), 'base', manifests.base, manifests, ids, runtime);
  assert.ok(results.some((r) => r.label === 'accountant chain set' && !r.ok));
});

test('deployment verification still defaults to the full supported registry', async () => {
  const results = await checkDeployment(provider(), 'base', manifests.base, manifests, ids);
  assert.ok(results.some((r) => r.label === 'peer mainnet manifest' && !r.ok));
});

test('missing new provider manifests produce pending checks rather than invalid-address RPC calls', async () => {
  const base = { ...manifests.base, contracts: { ...manifests.base.contracts } };
  delete base.contracts.FluidProvider;
  delete base.contracts.GauntletPrimeV2MorphoProvider;
  const results = await checkDeployment(provider(), 'base', base, { ...manifests, base }, ids, runtime);
  assert.deepEqual(results.filter((r) => r.label.startsWith('strategy provider manifest') && !r.ok)
    .map((r) => r.label), ['strategy provider manifest Fluid', 'strategy provider manifest GauntletPrimeV2Morpho']);
});

test('monitor rejects a Fluid provider bound to another source', async () => {
  const results = await checkDeployment(provider(undefined, true), 'base', manifests.base, manifests, ids, runtime);
  assert.ok(results.some((r) => r.label === 'strategy source Fluid' && !r.ok));
});
