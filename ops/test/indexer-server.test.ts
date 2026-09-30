import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import type { AddressInfo } from 'node:net';
import { createServer, Indexer } from '../src/indexer';

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
  const server = createServer(indexer, { lastSync: Date.now(), lastError: '' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => server.close());

  const port = (server.address() as AddressInfo).port;
  const response = await fetch(`http://127.0.0.1:${port}/v1/instant-remaining?dailyLimit=100`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { instantRemainingEstimate: '99' });
  assert.equal(vaultReads, 0);
});
