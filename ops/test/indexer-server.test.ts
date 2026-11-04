import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import type { AddressInfo } from 'node:net';
import { createServer, Indexer } from '../src/indexer';

const listen = async (indexer: Indexer, state: { lastSync: number; lastError: string }) => {
  const server = createServer(indexer, state);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { server, origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
};

test('instant remaining endpoint avoids the RPC-backed vault summary', async (t) => {
  let vaultReads = 0;
  const indexer = {
    lag: () => ({}),
    vaultSummary: async () => {
      vaultReads += 1;
      throw new Error('must not be called');
    },
    instantRemainingEstimate: (limit: bigint) => (limit - 1n).toString(),
  } as unknown as Indexer;
  const { server, origin } = await listen(indexer, { lastSync: Date.now(), lastError: '' });
  t.after(() => server.close());

  const response = await fetch(`${origin}/v1/instant-remaining?dailyLimit=100`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { instantRemainingEstimate: '99' });
  assert.equal(vaultReads, 0);
});

test('health tolerates one failed poll while the last successful sync is fresh', async (t) => {
  const indexer = { lag: () => ({ base: 123 }) } as unknown as Indexer;
  const { server, origin } = await listen(indexer, {
    lastSync: Date.now() - 30_000,
    lastError: 'transient provider failure',
  });
  t.after(() => server.close());

  const response = await fetch(`${origin}/health`);
  assert.equal(response.status, 200);
  const body = await response.json() as Record<string, unknown>;
  assert.equal(body.service, 'indexer');
  assert.equal(body.healthy, true);
  assert.equal(body.lastError, 'transient provider failure');
  assert.deepEqual(body.indexedTo, { base: 123 });
});
