import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { assertTrackedChainsConfigured, loadChains, loadRuntimeManifests } from '../src/config';

function fixture(run: (root: string) => void): void {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'xc-runtime-'));
  const saved = Object.fromEntries(['CROSSCHAIN_MANIFEST_DIR', 'CROSSCHAIN_NETWORKS', 'RPC_BASE', 'RPC_ARBITRUM', 'RPC_MAINNET'].map((key) => [key, process.env[key]]));
  try {
    process.env.CROSSCHAIN_MANIFEST_DIR = root;
    delete process.env.CROSSCHAIN_NETWORKS;
    for (const key of ['base', 'arbitrum']) {
      fs.mkdirSync(path.join(root, key));
      fs.copyFileSync(path.join(__dirname, '..', '..', 'deployments', key, 'crosschain.json'), path.join(root, key, 'crosschain.json'));
      delete process.env[`RPC_${key.toUpperCase()}`];
    }
    delete process.env.RPC_MAINNET;
    run(root);
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test('runtime discovers the deployed Base/Arbitrum set without Ethereum or its RPC', () => fixture(() => {
  assert.deepEqual(loadRuntimeManifests().map(({ key }) => key), ['base', 'arbitrum']);
  process.env.RPC_BASE = 'http://127.0.0.1:1';
  process.env.RPC_ARBITRUM = 'http://127.0.0.1:1';
  const chains = loadChains();
  try { assert.deepEqual(chains.map((c) => c.chainId), [8453n, 42161n]); }
  finally { for (const chain of chains) chain.provider.destroy(); }
}));

test('explicit selection preserves order and fails on a missing selected manifest before RPC configuration', () => fixture(() => {
  process.env.CROSSCHAIN_NETWORKS = 'arbitrum, base';
  assert.deepEqual(loadRuntimeManifests().map(({ key }) => key), ['arbitrum', 'base']);
  process.env.CROSSCHAIN_NETWORKS = 'base,arbitrum,mainnet';
  assert.throws(() => loadChains(), /missing manifest .*mainnet/);
}));

test('invalid explicit selections never silently fall back to discovered manifests', () => fixture(() => {
  for (const selected of ['', ' ', 'base,', ',base', 'base,,arbitrum', 'base,base', 'base,typo', 'base,__proto__']) {
    process.env.CROSSCHAIN_NETWORKS = selected;
    assert.throws(() => loadRuntimeManifests(), /CROSSCHAIN_NETWORKS:/, selected);
  }
  process.env.CROSSCHAIN_NETWORKS = 'arbitrum';
  assert.throws(() => loadRuntimeManifests(), /exactly one hub/);
}));

test('present malformed or misidentified manifests are rejected instead of skipped', () => fixture((root) => {
  const file = path.join(root, 'arbitrum', 'crosschain.json');
  const original = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const patch of [{ network: 'base' }, { chainId: '1' }, { role: 'hub' }]) {
    fs.writeFileSync(file, JSON.stringify({ ...original, ...patch }));
    assert.throws(() => loadRuntimeManifests(), /manifest identity mismatch/);
  }
  fs.writeFileSync(file, '{broken');
  assert.throws(() => loadRuntimeManifests(), SyntaxError);
}));

test('a staged Ethereum manifest is discovered without changing the deployment registry', () => fixture((root) => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'arbitrum', 'crosschain.json'), 'utf8'));
  fs.mkdirSync(path.join(root, 'mainnet'));
  fs.writeFileSync(path.join(root, 'mainnet', 'crosschain.json'), JSON.stringify({ ...manifest, network: 'mainnet', chainId: '1' }));
  assert.deepEqual(loadRuntimeManifests().map(({ key }) => key), ['base', 'arbitrum', 'mainnet']);
}));

test('selected deployments require their own RPC configuration', () => fixture(() => {
  const savedLegacy = process.env.BASE_RPC_URL;
  delete process.env.BASE_RPC_URL;
  try { assert.throws(() => loadChains(), /no RPC for base/); }
  finally { if (savedLegacy !== undefined) process.env.BASE_RPC_URL = savedLegacy; }
}));

test('missing or empty manifest sets cannot start a hubless runtime', () => fixture((root) => {
  fs.rmSync(path.join(root, 'base'), { recursive: true });
  assert.throws(() => loadRuntimeManifests(), /exactly one hub/);
  fs.rmSync(path.join(root, 'arbitrum'), { recursive: true });
  assert.throws(() => loadRuntimeManifests(), /no networks/);
}));

test('preflight coverage rejects omitted active chains and allows staged extra chains', () => {
  const deployed = [{ chainId: 8453n }, { chainId: 42161n }];
  assert.doesNotThrow(() => assertTrackedChainsConfigured(deployed, [42161n, 8453n]));
  assert.throws(() => assertTrackedChainsConfigured(deployed, [1n, 8453n, 42161n]), /not configured here: 1/);
  assert.doesNotThrow(() => assertTrackedChainsConfigured([...deployed, { chainId: 1n }], [8453n, 42161n]));
});
