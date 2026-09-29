import { test } from 'node:test';
import assert from 'node:assert/strict';
import { drainCursor } from '../src/keeper-cursor';

test('drainCursor waits for the read RPC cursor before another transaction', async () => {
  const cursors = [5n, 5n, 5n, 6n, 6n];
  const events: string[] = [];
  let attempts = 0;

  const completed = await drainCursor(
    async () => {
      attempts += 1;
      events.push(`attempt:${attempts}`);
      return attempts === 1;
    },
    async () => {
      const cursor = cursors.shift()!;
      events.push(`cursor:${cursor}`);
      return cursor;
    },
    { label: 'clearRedeems', maxPolls: 4, pause: async () => events.push('pause') },
  );

  assert.equal(completed, 1);
  assert.deepEqual(events, [
    'cursor:5', 'attempt:1', 'cursor:5', 'pause', 'cursor:5', 'pause',
    'cursor:6', 'attempt:2',
  ]);
});

test('drainCursor stops instead of broadcasting a duplicate when reads stay stale', async () => {
  let attempts = 0;
  await assert.rejects(
    drainCursor(
      async () => { attempts += 1; return true; },
      async () => 9n,
      { label: 'clearDeposits', maxPolls: 3, pause: async () => undefined },
    ),
    /clearDeposits confirmed but the read RPC cursor did not advance after 3 polls/,
  );
  assert.equal(attempts, 1);
});
