import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { Interface, Provider, zeroPadValue } from 'ethers';
import { ACCESS, ADAPTER, CHAIN_AGENT, EPOCH_VAULT, MORPHO_V2_VAULT, OWNABLE, PROVIDER, PROVIDER_MANAGER, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from '../src/abi';
import { checkDeployment } from '../src/checks/deployment';
import { HUB_PARAMS, NETWORKS } from '../../deploy/crosschain/registry';

const manifests = Object.fromEntries(['base', 'arbitrum'].map((key) => {
  const m = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'deployments', key, 'crosschain.json'), 'utf8'));
  // Candidate release manifest, not a claim that the two providers are deployed.
  Object.assign(m.contracts, {
    FluidProvider: '0x0000000000000000000000000000000000000f10',
    GauntletPrimeV2MorphoProvider: '0x0000000000000000000000000000000000000a20',
  });
  return [key, { ...m, codehashes: {} }];
}));
const runtime = Object.fromEntries(['base', 'arbitrum'].map((key) => [key, NETWORKS[key]]));
const abi = new Interface([...ACCESS, ...ADAPTER, ...CHAIN_AGENT, ...EPOCH_VAULT, ...MORPHO_V2_VAULT, ...OWNABLE, ...PROVIDER, ...PROVIDER_MANAGER, ...STRATEGY, ...TICK_ACCOUNTANT, ...TIMELOCK]);

/** The curator every genuine Gauntlet Morpho vault returns; see GAUNTLET_CURATOR in the check. */
const GAUNTLET_CURATOR = '0x9E33faAE38ff641094fa68c65c2cE600b3410585';
/** Stands in for one of the decoy vaults that copy a Gauntlet name under another curator. */
const DECOY_CURATOR = '0x1b0448bf6bD7eF8165A6350191d7338F5c2464f4';

/** Two-chain deployment fixture. Unexpected third-chain reads are errors. */
function provider({
  key = 'base', tracked = [8453n, 42161n], wrongFluidSource = false, wrongCurator = false, extraAdapters = true,
}: {
  key?: 'base' | 'arbitrum'; tracked?: bigint[]; wrongFluidSource?: boolean; wrongCurator?: boolean; extraAdapters?: boolean;
} = {}): Provider {
  const m = manifests[key];
  const net = runtime[key];
  const c = m.contracts;
  const safe = m.deployer;
  const peers = Object.values(runtime);
  const providers = net.strategy.reusedProviders.map((p) => p.address);
  providers.splice(1, 0, c.CompoundV3Provider);
  if (extraAdapters) providers.push(c.FluidProvider, c.GauntletPrimeV2MorphoProvider);
  const caps = new Map(net.strategy.reusedProviders.map((p) => [p.address.toLowerCase(), net.strategy.capsBps[p.label] ?? 0]));
  caps.set(c.CompoundV3Provider.toLowerCase(), net.strategy.capsBps.CompoundV3);
  caps.set(c.FluidProvider.toLowerCase(), net.strategy.capsBps.Fluid);
  caps.set(c.GauntletPrimeV2MorphoProvider.toLowerCase(), net.strategy.capsBps.GauntletPrimeV2Morpho);
  const implementations = new Map(['Strategy', 'ChainAgent', 'TickAccountant', 'EpochVault'].filter(name => c[name]).map((name) => [c[name].toLowerCase(), c[`${name}Implementation`]]));
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
          const dst = key === 'base' ? 'arbitrum' : 'base';
          const limits = net.routes[runtime[dst].chainId.toString()];
          value = [[c.CctpV2Adapter, runtime[dst].chainId, manifests[dst].contracts.ChainAgent, limits.maxFeeBps, true, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond, limits.capacity, 0]];
          break;
        }
        case 'getProviders': value = [providers]; break;
        case 'getEntryProvider': value = [providers[0]]; break;
        case 'getProviderCap': value = [caps.get(tx.args[0].toLowerCase())]; break;
        case 'getSource': value = [to.toLowerCase() === c.FluidProvider.toLowerCase()
          ? (wrongFluidSource ? net.strategy.morphoV2Vault : net.strategy.fluidFToken)
          : net.strategy.morphoV2Vault]; break;
        // checkDeployment reads the Morpho V2 vault directly, not through its provider,
        // because a registry that named a decoy would still pass the getSource check.
        case 'curator': value = [wrongCurator ? DECOY_CURATOR : GAUNTLET_CURATOR]; break;
        case 'asset': value = [net.usdc]; break;
        // CompoundV3Provider resolves its Comet through the ProviderManager, so
        // checkDeployment reads it back and compares against the registry. Every
        // call resolves the selected chain's market.
        case 'getYieldToken': value = [net.strategy.comet]; break;
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

test('monitor checks only the deployed runtime peers, without false Ethereum or Monad failures', async () => {
  const results = await checkDeployment(provider(), 'base', manifests.base, manifests, ids, runtime, 'monitor');
  assert.deepEqual(results.filter((r) => !r.ok), []);
  assert.ok(results.some((r) => r.label === 'accountant chain set'));
  assert.ok(!results.some((r) => r.label.includes('mainnet') || r.label.includes('monad')));
});

test('runtime selection cannot hide an extra active accountant chain from monitoring', async () => {
  const results = await checkDeployment(provider({ tracked: [1n, 8453n, 42161n] }), 'base', manifests.base, manifests, ids, runtime, 'monitor');
  assert.ok(results.some((r) => r.label === 'accountant chain set' && !r.ok));
});

test('deployment verification still defaults to the full supported registry', async () => {
  const results = await checkDeployment(provider(), 'base', manifests.base, manifests, ids);
  assert.ok(results.some((r) => r.label === 'peer mainnet manifest' && !r.ok));
  assert.ok(results.some((r) => r.label === 'peer monad manifest' && !r.ok));
});

test('missing new provider manifests produce pending checks rather than invalid-address RPC calls', async () => {
  const base = { ...manifests.base, contracts: { ...manifests.base.contracts } };
  delete base.contracts.FluidProvider;
  delete base.contracts.GauntletPrimeV2MorphoProvider;
  const results = await checkDeployment(provider(), 'base', base, { ...manifests, base }, ids, runtime, 'monitor');
  assert.deepEqual(results.filter((r) => r.label.startsWith('strategy provider manifest') && !r.ok)
    .map((r) => r.label), ['strategy provider manifest Fluid', 'strategy provider manifest GauntletPrimeV2Morpho']);
});

test('monitor rejects a Fluid provider bound to another source', async () => {
  const results = await checkDeployment(provider({ wrongFluidSource: true }), 'base', manifests.base, manifests, ids, runtime, 'monitor');
  assert.ok(results.some((r) => r.label === 'strategy source Fluid' && !r.ok));
});

test('Arbitrum monitor validates all seven providers and rejects a retargeted source', async () => {
  const good = await checkDeployment(provider({ key: 'arbitrum' }), 'arbitrum', manifests.arbitrum, manifests, ids, runtime, 'monitor');
  assert.deepEqual(good.filter(r => !r.ok), []);
  assert.ok(good.some(r => r.label === 'strategy source Fluid' && r.ok));
  assert.ok(good.some(r => r.label === 'strategy source GauntletPrimeV2Morpho' && r.ok));
  const wrong = await checkDeployment(provider({ key: 'arbitrum', wrongFluidSource: true }), 'arbitrum', manifests.arbitrum, manifests, ids, runtime, 'monitor');
  assert.ok(wrong.some(r => r.label === 'strategy source Fluid' && !r.ok));
});

test('monitor rejects a Morpho V2 vault curated by someone other than Gauntlet', async () => {
  // Six V2 vaults on Ethereum and Arbitrum copy a Gauntlet name and symbol; two are decoys,
  // one of them a 15% performance fee wrapper under another curator. Its provider still
  // resolves to whatever the registry names, so only curator() catches it.
  const clean = await checkDeployment(provider(), 'base', manifests.base, manifests, ids, runtime, 'monitor');
  assert.deepEqual(clean.filter((r) => r.label === 'morpho v2 curator' && !r.ok), [], 'the genuine curator passes');
  assert.ok(clean.some((r) => r.label === 'morpho v2 curator'), 'the curator is checked at all');

  const results = await checkDeployment(provider({ wrongCurator: true }), 'base', manifests.base, manifests, ids, runtime, 'monitor');
  const failed = results.filter((r) => r.label === 'morpho v2 curator' && !r.ok);
  assert.equal(failed.length, 1, 'a decoy curator fails exactly one check');
  assert.ok(failed[0].detail.includes(DECOY_CURATOR), 'the report names the curator it found');
  assert.deepEqual(results.filter((r) => r.label === 'strategy source GauntletPrimeV2Morpho' && !r.ok), [],
    'the source check alone would not have caught it');
});

test('only runtime monitoring accepts the exact five-provider Arbitrum set while activation is pending', async () => {
  const arbitrum = { ...manifests.arbitrum, contracts: { ...manifests.arbitrum.contracts } };
  delete arbitrum.contracts.FluidProvider;
  delete arbitrum.contracts.GauntletPrimeV2MorphoProvider;
  const chain = provider({ key: 'arbitrum', extraAdapters: false });
  const active = { ...manifests, arbitrum };
  const monitored = await checkDeployment(chain, 'arbitrum', arbitrum, active, ids, runtime, 'monitor');
  assert.deepEqual(monitored.filter(r => !r.ok), []);
  assert.equal(monitored.filter(r => r.label.startsWith('pending provider registration ')).length, 2);
  assert.ok(!monitored.some(r => r.label === 'morpho v2 curator'));
  const strict = await checkDeployment(chain, 'arbitrum', arbitrum, active, ids, runtime);
  assert.deepEqual(strict.filter(r => !r.ok).map(r => r.label), [
    'strategy provider manifest Fluid', 'strategy provider manifest GauntletPrimeV2Morpho',
  ]);
  const unrecorded = await checkDeployment(provider({ key: 'arbitrum' }), 'arbitrum', arbitrum, active, ids, runtime, 'monitor');
  assert.ok(unrecorded.some(r => r.label === 'strategy providers' && !r.ok));
  const substituted = { ...arbitrum, contracts: { ...arbitrum.contracts, CompoundV3Provider: manifests.arbitrum.contracts.FluidProvider } };
  const drift = await checkDeployment(chain, 'arbitrum', substituted, { ...active, arbitrum: substituted }, ids, runtime, 'monitor');
  assert.ok(drift.some(r => r.label === 'strategy providers' && !r.ok));
});
