import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { AbiCoder, Interface, getAddress, keccak256 } from 'ethers';
import {
  ReadOnlyRpc, appendProvider, registrationProposal, discoverTargets, writeBundle, cleanError, assertRuntimeMatches,
} from '../../scripts/prepare-gauntlet-v2-deploy';

const a = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`);

test('registration preserves all current providers and their order', () => {
  const current = [a(3), a(1), a(2)];
  assert.deepEqual(appendProvider(current, a(4)), [...current, a(4)]);
  assert.deepEqual(current, [a(3), a(1), a(2)]);
  assert.deepEqual(appendProvider(current, a(1)), current);
  assert.throws(() => appendProvider([a(1), a(1)], a(2)), /duplicates/);
});

test('queue, execute and cancel bind the same timelock tuple and complete provider list', () => {
  const plan = registrationProposal(a(10), a(11), a(12), [a(1), a(2)], a(3), 1_000, 1_800);
  const iface = new Interface([
    'function queue(address,uint256,string,bytes,uint256)',
    'function execute(address,uint256,string,bytes,uint256)',
    'function cancel(address,uint256,string,bytes,uint256)',
  ]);
  const queue = iface.decodeFunctionData('queue', plan.queue.data);
  assert.equal(plan.queue.from, a(12));
  assert.equal(plan.queue.to, a(11));
  assert.equal(plan.registrationCall.from, a(11));
  assert.equal(plan.registrationCall.to, a(10));
  assert.equal(plan.eta, 6_400);
  assert.deepEqual(Array.from(AbiCoder.defaultAbiCoder().decode(['address[]'], queue[3])[0]), [a(1), a(2), a(3)]);
  assert.deepEqual(Array.from(iface.decodeFunctionData('execute', plan.execute.data)), Array.from(queue));
  assert.deepEqual(Array.from(iface.decodeFunctionData('cancel', plan.cancel.data)), Array.from(queue));
  assert.equal(plan.transactionId, keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], Array.from(queue))));
  assert.throws(() => registrationProposal(a(10), a(11), a(12), [], a(3), 100, -1), /timing/);
});

for (const method of ['eth_sendTransaction', 'eth_sendRawTransaction', 'eth_sign', 'personal_sign',
  'eth_accounts', 'hardhat_setCode', 'anvil_setCode', 'evm_mine']) {
  test(`preparation blocks ${method} at both RPC boundaries without a connection`, async () => {
    const rpc = new ReadOnlyRpc('http://127.0.0.1:1', 1, { staticNetwork: true });
    try {
      await assert.rejects(rpc.send(method, []), /Preparation forbids RPC method/);
      await assert.rejects(rpc._send([
        { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] },
        { jsonrpc: '2.0', id: 2, method, params: [] },
      ]), /Preparation forbids RPC method/);
    } finally { rpc.destroy(); }
  });
}

test('bundle creation refuses overwrites and filename path traversal', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gauntlet-plan-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const out = path.join(dir, 'bundle');
  writeBundle(out, { 'manifest.json': { mode: 'READ_ONLY' } });
  assert.throws(() => writeBundle(out, { 'manifest.json': { mode: 'CHANGED' } }), /EEXIST/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(out, 'manifest.json'), 'utf8')).mode, 'READ_ONLY');
  assert.throws(() => writeBundle(path.join(dir, 'invalid'), { '../escape.json': {} }), /filename/);
  assert.equal(fs.existsSync(path.join(dir, 'escape.json')), false);
});

test('target discovery keeps the main vault and stand strategy separate, never the EpochVault', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gauntlet-target-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const records = path.join(dir, 'deployments', 'base');
  fs.mkdirSync(records, { recursive: true });
  fs.writeFileSync(path.join(records, 'USDCRebalancerProxy.json'), JSON.stringify({ address: a(1) }));
  fs.writeFileSync(path.join(records, 'crosschain.json'), JSON.stringify({
    profile: 'stand', contracts: { Strategy: a(2), EpochVault: a(3) },
  }));
  assert.deepEqual(discoverTargets('base', dir), [
    { label: 'main-usdc-vault', address: a(1) },
    { label: 'crosschain-strategy', address: a(2), profile: 'stand' },
  ]);
});

test('RPC URLs are scrubbed from preparation errors', () => {
  const message = cleanError(new Error('request failed https://rpc.example/secret-token?key=private'));
  assert.equal(message, 'request failed [RPC URL]');
});

test('post-deployment registration requires exactly the compiled immutable runtime', () => {
  assert.doesNotThrow(() => assertRuntimeMatches('0x60006000', '0x60006000'));
  assert.throws(() => assertRuntimeMatches('0x', '0x60006000'), /refuse registration/);
  assert.throws(() => assertRuntimeMatches('0x60006001', '0x60006000'), /refuse registration/);
});

test('CLI rejects send/approval flags before reading addresses, artifacts or RPC', () => {
  const script = path.resolve(__dirname, '../../scripts/prepare-gauntlet-v2-deploy.ts');
  const result = spawnSync(process.execPath,
    ['--require', 'ts-node/register/transpile-only', script, '--send'], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /this tool cannot deploy/);
});
