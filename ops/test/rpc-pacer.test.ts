import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RequestPacer, rpcWeight } from '../src/rpc-pacer';

test('RPC starts are spaced across concurrent callers, also after idle', async () => {
  const pacer = new RequestPacer(50);
  const starts: number[] = [];
  const burst = () => Promise.all(Array.from({ length: 5 }, async () => {
    await pacer.acquire();
    starts.push(performance.now());
  }));
  await burst();
  await new Promise((r) => setTimeout(r, 60));
  await burst();
  for (let i = 1; i < starts.length; i++) assert.ok(starts[i] - starts[i - 1] >= 18);
  for (const invalid of [0, -1, NaN, Infinity]) assert.throws(() => new RequestPacer(invalid));
});

test('weighted pacing charges history scans more than live calls', async () => {
  assert.equal(rpcWeight('eth_getLogs'), 12);
  assert.equal(rpcWeight('eth_call', [{}, 'latest']), 3);
  assert.equal(rpcWeight('eth_call', [{}, '0x123']), 12);
  assert.equal(rpcWeight('eth_getTransactionReceipt'), 8);
  const pacer = new RequestPacer(100);
  await pacer.acquire(12);
  const start = performance.now();
  await pacer.acquire(3);
  assert.ok(performance.now() - start >= 115, '12 CU reserves 120 ms at 100 CU/s');
});
