import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { NETWORKS, hubEntry, providerLabels, strategyProviders } from '../../deploy/crosschain/registry';
import { chainConfigs } from '../../utils/constants';

const deployments = path.join(__dirname, '..', '..', 'deployments');

test('every reused provider and the Compound Comet match their committed record', () => {
  for (const [key, net] of Object.entries(NETWORKS)) {
    for (const { label, address } of net.strategy.reusedProviders) {
      const file = path.join(deployments, key, `${label}Provider.json`);
      assert.ok(existsSync(file), `${key}: no deployment record ${label}Provider.json`);
      const record = JSON.parse(readFileSync(file, 'utf8'));
      assert.equal(address.toLowerCase(), record.address.toLowerCase(), `${key}: ${label} address`);
    }
    // The Comet is the one strategy address with no deployments/<key> record: phase 1
    // takes it from here and writes it into the ProviderManager, so nothing else in the
    // tree corroborates the value. utils/constants.ts is the table the live single-chain
    // vaults were deployed from; agreeing with it pins both the Comet and the fact that
    // it is the market for THIS chain's USDC. checks/deployment.ts reads the on-chain
    // value back at phase 4 and in the monitor.
    const pairs = (chainConfigs[Number(net.chainId)]?.cometPairs ?? []).filter((p) => p.asset.toLowerCase() === net.usdc.toLowerCase());
    if (net.strategy.comet) {
      assert.equal(pairs.length, 1, `${key}: utils/constants.ts names ${pairs.length} Comets for USDC ${net.usdc}, expected exactly one`);
      assert.equal(net.strategy.comet.toLowerCase(), pairs[0].cToken.toLowerCase(), `${key}: strategy.comet`);
    } else {
      assert.equal(pairs.length, 0, `${key}: utils/constants.ts names a Comet for this USDC but the registry has none`);
    }
  }
});

test('caps name known providers and leave the entry provider uncapped', () => {
  for (const [key, net] of Object.entries(NETWORKS)) {
    const labels = providerLabels(net);
    for (const label of Object.keys(net.strategy.capsBps)) assert.ok(labels.includes(label), `${key}: cap for unknown provider ${label}`);
    assert.equal(net.strategy.capsBps[labels[0]] ?? 0, 0, `${key}: the entry provider ${labels[0]} must stay uncapped`);
    for (const [label, bps] of Object.entries(net.strategy.capsBps)) assert.ok(bps >= 0 && bps <= 10_000, `${key}: cap ${label} ${bps} bps`);
  }
});

test('strategy providers: entry first, fresh Compound second, fresh Fluid and V2 last, as phase 1 builds them', () => {
  const mainnet = NETWORKS.mainnet;
  const fresh = {
    CompoundV3Provider: '0x00000000000000000000000000000000000000c3',
    FluidProvider: '0x00000000000000000000000000000000000000f1',
    GauntletPrimeV2MorphoProvider: '0x00000000000000000000000000000000000000a2',
  };
  assert.deepEqual(
    strategyProviders(mainnet, fresh).map((p) => p.label),
    ['SteakhouseMorpho', 'CompoundV3', 'GauntletPrimeMorpho', 'SmokehouseMorpho', 'AaveV3', 'Fluid', 'GauntletPrimeV2Morpho'],
  );
  assert.equal(strategyProviders(mainnet, fresh).at(-1)!.address, fresh.GauntletPrimeV2MorphoProvider);
  assert.deepEqual(
    strategyProviders(mainnet, { CompoundV3Provider: fresh.CompoundV3Provider }).map((p) => p.label),
    ['SteakhouseMorpho', 'CompoundV3', 'GauntletPrimeMorpho', 'SmokehouseMorpho', 'AaveV3'],
    'a fresh provider not deployed yet is absent',
  );
  for (const [key, net] of Object.entries(NETWORKS)) {
    // the manifest phase 1 leaves: only the fresh providers the entry asks for
    const deployed: Record<string, string> = {};
    if (net.strategy.comet) deployed.CompoundV3Provider = fresh.CompoundV3Provider;
    if (net.strategy.fluidFToken) deployed.FluidProvider = fresh.FluidProvider;
    if (net.strategy.morphoV2Vault) deployed.GauntletPrimeV2MorphoProvider = fresh.GauntletPrimeV2MorphoProvider;
    assert.deepEqual(strategyProviders(net, deployed).map((p) => p.label).sort(), providerLabels(net).sort(), `${key}: every label is listed once`);
  }
});

test('Base expansion appends Fluid and V2 while retaining the five original venues', () => {
  const base = NETWORKS.base;
  const addresses = {
    CompoundV3Provider: '0x0000000000000000000000000000000000000001',
    FluidProvider: '0x0000000000000000000000000000000000000002',
    GauntletPrimeV2MorphoProvider: '0x0000000000000000000000000000000000000003',
  };
  assert.deepEqual(strategyProviders(base, addresses).map((p) => p.label), [
    'AaveV3', 'CompoundV3', 'GauntletCoreMorpho', 'SteakhouseHighYieldMorpho',
    'SteakhousePrimeMorpho', 'Fluid', 'GauntletPrimeV2Morpho',
  ]);
  assert.equal(base.strategy.fluidFToken, '0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169');
  assert.equal(base.strategy.morphoV2Vault, chainConfigs[8453].morphoVaults.find((v) => v.version === 2)!.vaultAddress);
  assert.equal(base.strategy.capsBps.Fluid, 3_000);
  assert.equal(base.strategy.capsBps.GauntletPrimeV2Morpho, 2_000);
});

test('Ethereum expands with Aave, Fluid and Morpho V2', () => {
  const mainnet = NETWORKS.mainnet;
  assert.equal(mainnet.strategy.morphoV2Vault, chainConfigs[1].morphoVaults.find((v) => v.version === 2)!.vaultAddress);
  assert.equal(mainnet.strategy.capsBps.GauntletPrimeV2Morpho, 2_000);
  assert.equal(mainnet.strategy.capsBps.Fluid, 3_000);
  // Provider parity with the standalone Ethereum vault, which already runs this
  // AaveV3Provider. It is appended, so Steakhouse stays the entry provider.
  const aave = mainnet.strategy.reusedProviders.find((p) => p.label === 'AaveV3');
  assert.ok(aave, 'mainnet: AaveV3 is registered');
  assert.equal(mainnet.strategy.reusedProviders[0].label, 'SteakhouseMorpho', 'the entry provider is unchanged');
  assert.equal(aave!.address, '0x107DA8Bd8a6DBaB9823E316e10abCDaC4d4D6941');
});

test('Monad is an Aave-only spoke whose single provider is also its entry', () => {
  const monad = NETWORKS.monad;
  assert.equal(monad.role, 'spoke');
  assert.equal(monad.chainId, 143n);
  // Measured on-chain: MessageTransmitter.localDomain() on Monad returns 15, and both CCTP
  // contracts carry the same runtime codehash there as on Base, Arbitrum and Ethereum.
  assert.equal(monad.cctp.domain, 15);
  assert.equal(monad.usdc.toLowerCase(), chainConfigs[143].asset.toLowerCase(), 'the spoke asset is Monad USDC');

  // Aave is the only venue Monad has that this registry can name, so it is the whole strategy
  // and therefore the entry provider, which has to stay uncapped.
  assert.deepEqual(monad.strategy.reusedProviders, [
    { label: 'AaveV3', address: '0xAeEcf7F780e88B155df330434Ef29b2B077024e0' },
  ]);
  assert.deepEqual(monad.strategy.capsBps, { AaveV3: 0 });
  assert.deepEqual(strategyProviders(monad, {}).map((p) => p.label), ['AaveV3']);

  // chainConfigs[143] lists no Comet and no Morpho vault, and Fluid publishes no Monad
  // deployment, so none of the three optional venues may be set: setting `comet` would fail
  // the Comet cross-check above, and the other two would deploy a provider over a market
  // that does not exist.
  assert.equal(monad.strategy.comet, undefined);
  assert.equal(monad.strategy.fluidFToken, undefined);
  assert.equal(monad.strategy.morphoV2Vault, undefined);
  assert.deepEqual(chainConfigs[143].cometPairs, []);
  assert.deepEqual(chainConfigs[143].morphoVaults, []);

  // 20 blocks at Monad's measured 0.307 s block time is about 6 s, the wall-clock depth
  // Arbitrum's 20 blocks give at 0.284 s. Not a measured reorg depth.
  assert.equal(monad.confirmations, 20);
  assert.deepEqual(Object.keys(monad.routes), ['8453'], 'routes to the hub only');
  assert.ok(NETWORKS.base.routes['143'], 'the hub routes back');
});

test('the hub routes to every spoke and every spoke routes back to the hub', () => {
  const [hubKey, hub] = hubEntry();
  for (const [key, net] of Object.entries(NETWORKS)) {
    if (key === hubKey) continue;
    assert.equal(net.role, 'spoke', `${key} role`);
    assert.ok(hub.routes[net.chainId.toString()], `no route ${hubKey} -> ${key}`);
    assert.ok(net.routes[hub.chainId.toString()], `no route ${key} -> ${hubKey}`);
  }
  for (const net of Object.values(NETWORKS)) {
    for (const dst of Object.keys(net.routes)) {
      assert.ok(Object.values(NETWORKS).some((n) => n.chainId.toString() === dst), `route to unknown chain ${dst}`);
    }
  }
});

test('chain ids and CCTP domains are unique', () => {
  const nets = Object.values(NETWORKS);
  assert.equal(new Set(nets.map((n) => n.chainId)).size, nets.length, 'chain ids');
  assert.equal(new Set(nets.map((n) => n.cctp.domain)).size, nets.length, 'CCTP domains');
});

test('Arbitrum expansion preserves legacy venues and uses distinct native-USDC sources', () => {
  const arb = NETWORKS.arbitrum;
  const manifest = JSON.parse(readFileSync(path.join(deployments, 'arbitrum/crosschain.json'), 'utf8'));
  const original = strategyProviders(arb, manifest.contracts);
  assert.equal(original.length, 5, 'committed manifest must not invent deployments');
  const adapters = { ...manifest.contracts,
    FluidProvider: '0x00000000000000000000000000000000000000f1',
    GauntletPrimeV2MorphoProvider: '0x00000000000000000000000000000000000000a2',
  };
  const expanded = strategyProviders(arb, adapters);
  assert.deepEqual(expanded.slice(0, 5), original);
  assert.deepEqual(expanded.map(p => p.label), ['AaveV3', 'CompoundV3', 'GauntletCoreMorpho',
    'SteakhouseHighYieldMorpho', 'SteakhousePrimeMorpho', 'Fluid', 'GauntletPrimeV2Morpho']);
  assert.equal(arb.usdc, '0xaf88d065e77c8cC2239327C5EDb3A432268e5831');
  assert.equal(arb.strategy.fluidFToken, '0x1A996cb54bb95462040408C06122D45D6Cdb6096');
  assert.equal(arb.strategy.morphoV2Vault, '0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78');
  assert.notEqual(arb.strategy.fluidFToken, NETWORKS.base.strategy.fluidFToken);
  assert.notEqual(arb.strategy.morphoV2Vault, NETWORKS.base.strategy.morphoV2Vault);
  assert.equal(arb.strategy.capsBps.Fluid, 3000);
  assert.equal(arb.strategy.capsBps.GauntletPrimeV2Morpho, 2000);
});
