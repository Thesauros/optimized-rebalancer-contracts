import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { NETWORKS, hubEntry, providerLabels, strategyProviders } from '../../deploy/crosschain/registry';

const deployments = path.join(__dirname, '..', '..', 'deployments');

test('every reused provider is the deployment record of that network', () => {
  for (const [key, net] of Object.entries(NETWORKS)) {
    for (const { label, address } of net.strategy.reusedProviders) {
      const file = path.join(deployments, key, `${label}Provider.json`);
      assert.ok(existsSync(file), `${key}: no deployment record ${label}Provider.json`);
      const record = JSON.parse(readFileSync(file, 'utf8'));
      assert.equal(address.toLowerCase(), record.address.toLowerCase(), `${key}: ${label} address`);
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

test('strategy providers: entry first, fresh Compound second, fresh Fluid last, as phase 1 builds them', () => {
  const mainnet = NETWORKS.mainnet;
  const fresh = { CompoundV3Provider: '0x00000000000000000000000000000000000000c3', FluidProvider: '0x00000000000000000000000000000000000000f1' };
  assert.deepEqual(
    strategyProviders(mainnet, fresh).map((p) => p.label),
    ['SteakhouseMorpho', 'CompoundV3', 'GauntletPrimeMorpho', 'SmokehouseMorpho', 'Fluid'],
  );
  assert.equal(strategyProviders(mainnet, fresh).at(-1)!.address, fresh.FluidProvider);
  assert.deepEqual(
    strategyProviders(mainnet, { CompoundV3Provider: fresh.CompoundV3Provider }).map((p) => p.label),
    ['SteakhouseMorpho', 'CompoundV3', 'GauntletPrimeMorpho', 'SmokehouseMorpho'],
    'a fresh provider not deployed yet is absent',
  );
  for (const [key, net] of Object.entries(NETWORKS)) {
    // the manifest phase 1 leaves: only the fresh providers the entry asks for
    const deployed: Record<string, string> = {};
    if (net.strategy.comet) deployed.CompoundV3Provider = fresh.CompoundV3Provider;
    if (net.strategy.fluidFToken) deployed.FluidProvider = fresh.FluidProvider;
    assert.deepEqual(strategyProviders(net, deployed).map((p) => p.label).sort(), providerLabels(net).sort(), `${key}: every label is listed once`);
  }
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
