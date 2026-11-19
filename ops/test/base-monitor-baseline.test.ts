import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Interface, Provider, ZeroAddress, keccak256, zeroPadValue } from 'ethers';
import { NETWORKS, strategyProviders } from '../../deploy/crosschain/registry';
import { ACCESS, ADAPTER, CHAIN_AGENT, EPOCH_VAULT, OWNABLE, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from '../src/abi';
import { checkDeployment, ManifestLike } from '../src/checks/deployment';

const sourceAbi = 'function getSource(address asset, address vault, address user) view returns (address)';
const abi = new Interface([...ACCESS, ...ADAPTER, ...CHAIN_AGENT, ...EPOCH_VAULT, ...OWNABLE, ...STRATEGY, ...TICK_ACCOUNTANT, ...TIMELOCK, sourceAbi]);
const load = (key: string) => JSON.parse(readFileSync(`${__dirname}/../../deployments/${key}/crosschain.json`, 'utf8'));
const pinned = load('base');
const lower = (value: string) => value.toLowerCase();
const code = '0x60016000';
const goodHash = keccak256(code);

function fixture(key = 'base') {
  const manifests: Record<string, ManifestLike> = { base: load('base'), arbitrum: load('arbitrum') };
  const m = manifests[key], entry = NETWORKS[key], c = m.contracts;
  for (const name of Object.keys(m.codehashes)) m.codehashes[name] = goodHash;
  const listed = strategyProviders(entry, c);
  const state = {
    providers: listed.map((p) => p.address),
    caps: new Map(listed.map((p) => [lower(p.address), BigInt(entry.strategy.capsBps[p.label])])),
    sources: new Map([[lower(c.FluidProvider ?? ZeroAddress), entry.strategy.fluidFToken], [lower(c.GauntletPrimeV2MorphoProvider ?? ZeroAddress), entry.strategy.morphoV2Vault]]),
    codeOverrides: new Map<string, string>(), implementationOverrides: new Map<string, string>(),
    owner: m.deployer, rpcFailure: false, sourceCalls: [] as { to: string; args: readonly unknown[] }[],
  };
  const impls = new Map(['Strategy', 'ChainAgent', 'TickAccountant', 'EpochVault'].filter((name) => c[name]).map((name) => [lower(c[name]), c[`${name}Implementation`]]));
  const provider = {
    getStorage: async (at: string, slot: string) => zeroPadValue(slot.startsWith('0x3608') ? state.implementationOverrides.get(lower(at)) ?? impls.get(lower(at))! : '0x0000000000000000000000000000000000000010', 32),
    getCode: async (at: string) => state.codeOverrides.get(lower(at)) ?? code,
    call: async (tx: { to: string; data: string }) => {
      const parsed = abi.parseTransaction({ data: tx.data })!;
      const peerKey = key === 'base' ? 'arbitrum' : 'base', peer = NETWORKS[peerKey], pm = manifests[peerKey].contracts;
      let result: unknown[];
      switch (parsed.name) {
        case 'owner': result = [state.owner]; break;
        case 'hasRole': case 'isAdapter': case 'isPeer': case 'isAgent': result = [true]; break;
        case 'getTimelock': case 'governance': result = [c.Timelock]; break;
        case 'agent': result = [c.ChainAgent]; break;
        case 'strategy': result = [c.Strategy]; break;
        case 'vault': result = [c.EpochVault]; break;
        case 'remotes': result = [peer.cctp.domain, pm.CctpV2Adapter, true]; break;
        case 'getRoute': {
          const r = entry.routes[peer.chainId.toString()];
          result = [[c.CctpV2Adapter, peer.chainId, pm.ChainAgent, r.maxFeeBps, true, r.maxPerTransfer, r.capacity, r.refillPerSecond, 0, 0]]; break;
        }
        case 'getProviders': result = [state.providers]; break;
        case 'getEntryProvider': result = [entry.strategy.reusedProviders[0].address]; break;
        case 'getProviderCap': result = [state.caps.get(lower(parsed.args[0])) ?? 0n]; break;
        case 'getSource':
          if (state.rpcFailure) throw new Error('fixture RPC unavailable');
          state.sourceCalls.push({ to: lower(tx.to), args: Array.from(parsed.args) });
          result = [state.sources.get(lower(tx.to))]; break;
        case 'accountant': result = [c.TickAccountant]; break;
        case 'hubAgent': result = [c.ChainAgent]; break;
        case 'chainIds': result = [[8453n, 42161n]]; break;
        case 'getFees': result = [0, 0, 0, m.deployer]; break;
        case 'config': result = [[300, 480, 7200, 3600, 0, 0, 0, 0]]; break;
        case 'buckets': result = [[0, 0, 0, 0], [2n * 10n ** 15n, 0, 0, 0]]; break;
        case 'epochConfig': result = [[3600, 7200, 1, 8580]]; break;
        case 'limits': result = [[1000000, 100000000000, 0, 0, 0, 0, 25n * 10n ** 14n, 7200]]; break;
        case 'maxChainExposure': result = [0]; break;
        default: throw new Error(`unhandled fixture call ${parsed.name}`);
      }
      return abi.encodeFunctionResult(parsed.fragment, result);
    },
  } as unknown as Provider;
  return { m, manifests, state, run: () => checkDeployment(provider, key, m, manifests, { safe: m.deployer, executor: m.deployer, guardian: m.deployer, navUpdater: m.deployer }) };
}
const passed = (results: Awaited<ReturnType<typeof checkDeployment>>, label: string) => {
  const check = results.find((r) => r.label === label); assert.ok(check, `missing check: ${label}`); return check.ok;
};

test('Base pins the proven implementation, immutable sources, caps and original deployment history', () => {
  assert.equal(pinned.contracts.StrategyImplementation, '0x6909E3654B060f8D1507F4fE8c71B604cA79eb2D');
  assert.equal(pinned.codehashes.StrategyImplementation, '0x6a9f9388ac5290c7a04b2415178eed2c197d1f11079913870b167765a229026b');
  assert.equal(pinned.codehashes.FluidProvider, '0x5414d072553e7d04a8399198d870c156ea20d70cc117616c92bd255fd8b9cf14');
  assert.equal(pinned.codehashes.GauntletPrimeV2MorphoProvider, '0x5e09a5d4f8bbb1e127df10d962d9dc8f335b8ab4cfec9476409b7b8bd93a5020');
  assert.equal(pinned.deploymentHistory[0].previous.address, '0xfcE142db5FD78F64c97b04d9a587E2C53341b910');
  assert.equal(pinned.deploymentHistory[0].previous.deploymentTx, '0x13b9ebfaa2171b8658b09f18df490dcb7cea462a48d1877e368332d2ae4782d2');
  assert.equal(NETWORKS.base.strategy.fluidFToken, '0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169');
  assert.equal(NETWORKS.base.strategy.morphoV2Vault, '0x050cE30b927Da55177A4914EC73480238BAD56f0');
  assert.equal(NETWORKS.base.strategy.capsBps.Fluid, 3000); assert.equal(NETWORKS.base.strategy.capsBps.GauntletPrimeV2Morpho, 2000);
  assert.deepEqual(Object.keys(NETWORKS), ['base', 'arbitrum']);
  assert.equal(pinned.txs.FluidProvider, undefined, 'unknown provider creation transactions are not invented');
});

test('Base provider order appends Fluid and Morpho V2; all original checks and Arbitrum remain healthy', async () => {
  assert.deepEqual(strategyProviders(NETWORKS.base, pinned.contracts).map((p) => p.label), ['AaveV3', 'CompoundV3', 'GauntletCoreMorpho', 'SteakhouseHighYieldMorpho', 'SteakhousePrimeMorpho', 'Fluid', 'GauntletPrimeV2Morpho']);
  for (const key of ['base', 'arbitrum']) {
    const f = fixture(key), results = await f.run(); assert.deepEqual(results.filter((r) => !r.ok), []);
    for (const label of ['Strategy ProxyAdmin owner', 'Strategy implementation', 'Strategy implementation code', 'Timelock owner', 'ChainAgent timelock = Timelock', 'CctpV2Adapter governance = Timelock', 'strategy providers']) assert.ok(passed(results, label));
    if (key === 'base') {
      assert.equal(f.state.sourceCalls.length, 2);
      for (const call of f.state.sourceCalls) assert.deepEqual(call.args, [NETWORKS.base.usdc, pinned.contracts.Strategy, ZeroAddress]);
      assert.ok(passed(results, 'maxClearingDelay covers maxTickAge + maxSnapshotAge'));
    } else assert.equal(f.state.sourceCalls.length, 0);
  }
});

test('missing configured provider manifests fail closed without undefined contract calls', async () => {
  const f = fixture(); delete f.m.contracts.FluidProvider; delete f.m.contracts.GauntletPrimeV2MorphoProvider; f.state.providers = f.state.providers.slice(0, 5);
  const results = await f.run();
  for (const label of ['strategy provider manifest Fluid', 'strategy provider manifest GauntletPrimeV2Morpho']) assert.equal(passed(results, label), false);
  assert.equal(f.state.sourceCalls.length, 0);
});

test('provider identity, cap, list and runtime drift are independently detected', async () => {
  const f = fixture(); f.state.providers.reverse(); f.state.sources.set(lower(pinned.contracts.FluidProvider), ZeroAddress);
  f.state.caps.set(lower(pinned.contracts.GauntletPrimeV2MorphoProvider), 3000n); f.state.codeOverrides.set(lower(pinned.contracts.GauntletPrimeV2MorphoProvider), '0x6002');
  const results = await f.run();
  for (const label of ['strategy providers', 'strategy source Fluid', 'strategy cap GauntletPrimeV2Morpho', 'strategy provider code GauntletPrimeV2Morpho']) assert.equal(passed(results, label), false);
});

test('missing pinned runtime, absent code and failed RPC cannot pass as healthy', async () => {
  const f = fixture(); delete f.m.codehashes.FluidProvider; f.state.codeOverrides.set(lower(pinned.contracts.GauntletPrimeV2MorphoProvider), '0x');
  const results = await f.run();
  for (const label of ['strategy provider code Fluid', 'strategy provider code GauntletPrimeV2Morpho']) assert.equal(passed(results, label), false);
  const unavailable = fixture(); unavailable.state.rpcFailure = true; await assert.rejects(unavailable.run(), /fixture RPC unavailable/);
});

test('original implementation and governance owner drift checks stay enforced', async () => {
  const f = fixture(); f.state.implementationOverrides.set(lower(pinned.contracts.Strategy), ZeroAddress); f.state.codeOverrides.set(lower(ZeroAddress), '0x'); f.state.owner = ZeroAddress;
  const results = await f.run();
  for (const label of ['Strategy implementation', 'Strategy implementation code', 'Strategy ProxyAdmin owner', 'Timelock owner', 'ProviderManager owner = Safe']) assert.equal(passed(results, label), false);
});
