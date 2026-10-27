import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RequestCursor } from '../src/keeper-requests';

test('request discovery includes pending IDs, skips settled IDs, and checks new arrivals', async () => {
  const cursor = new RequestCursor();
  const statuses = [0, 3, 2, 1];
  const seen: bigint[] = [];
  const read = async (id: bigint) => { seen.push(id); return { status: statuses[Number(id)] ?? 0 }; };
  await cursor.scan(read);
  assert.deepEqual([...cursor.pending], ['3']);
  assert.deepEqual(seen, [1n, 2n, 3n, 4n]);
  statuses.push(1);
  seen.length = 0;
  await cursor.scan(read);
  assert.deepEqual(seen, [4n, 5n]);
  assert.deepEqual([...cursor.pending], ['3', '4']);
});

test('discovery is bounded and never skips a failed read', async () => {
  const cursor = new RequestCursor();
  let fail = true;
  const seen: bigint[] = [];
  const read = async (id: bigint) => {
    seen.push(id);
    if (id === 2n && fail) throw new Error('RPC failure');
    return { status: 1 };
  };
  await assert.rejects(cursor.scan(read));
  assert.deepEqual([...cursor.pending], ['1']);
  fail = false;
  seen.length = 0;
  await cursor.scan(read, 2);
  assert.deepEqual(seen, [2n, 3n]);
  assert.deepEqual([...cursor.pending], ['1', '2', '3']);
});
