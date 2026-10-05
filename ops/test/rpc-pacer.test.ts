import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RequestPacer } from '../src/rpc-pacer';

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
