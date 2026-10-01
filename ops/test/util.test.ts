import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Contract, Interface, zeroPadValue, toBeHex } from 'ethers';
import { EventCache, retryTransient, scanMany, semaphore } from '../src/util';

const ABI = ['event A(uint256 indexed n)', 'event B(uint256 indexed n)'];
const iface = new Interface(ABI);
const ADDRESS = '0x00000000000000000000000000000000000000aa';

/** A provider shaped like Moralis: eth_getLogs over more than 100 blocks fails. */
function fakeProvider(events: { block: number; name: 'A' | 'B' }[], maxRange: number) {
  const calls: [number, number][] = [];
  return {
    calls,
    provider: {
      async getLogs(f: { fromBlock: number; toBlock: number; topics: string[][] }) {
        calls.push([f.fromBlock, f.toBlock]);
        if (f.toBlock - f.fromBlock + 1 > maxRange) {
          throw Object.assign(new Error('bad response'), {
            info: { responseBody: `{"code":400,"message":"'eth_getLogs' Exceeded maximum block range: ${maxRange}"}` },
          });
        }
        return events
          .filter((e) => e.block >= f.fromBlock && e.block <= f.toBlock && f.topics[0].includes(iface.getEvent(e.name)!.topicHash))
          .map((e, i) => ({
            address: ADDRESS,
            blockNumber: e.block,
            transactionHash: zeroPadValue(toBeHex(e.block), 32),
            index: i,
            ...iface.encodeEventLog(e.name, [e.block]),
          }));
      },
    },
  };
}

test('scanMany adapts to the provider range limit and returns every event in order', async () => {
  const events = [
    { block: 10, name: 'A' as const },
    { block: 150, name: 'B' as const },
    { block: 151, name: 'A' as const },
    { block: 999, name: 'B' as const },
  ];
  const fake = fakeProvider(events, 100);
  const c = new Contract(ADDRESS, ABI, fake.provider as any);
  const out = await scanMany(c, ['A', 'B'], 0, 1000);
  assert.deepEqual(out.map((e) => [e.blockNumber, e.eventName]), [[10, 'A'], [150, 'B'], [151, 'A'], [999, 'B']]);
  const ok = fake.calls.filter(([f, t]) => t - f + 1 <= 100);
  assert.ok(ok.every(([f, t]) => t - f + 1 === 100 || t === 1000), 'after the first failure every request uses the full stated range');
  assert.equal(ok.length, 11, '1001 blocks in 100-block requests, both event kinds in one request each');
});

test('scanMany bounds parallel log reads and keeps block-range order', async () => {
  const previous = process.env.LOG_CONCURRENCY;
  process.env.LOG_CONCURRENCY = '4';
  let active = 0;
  let peak = 0;
  const provider = {
    async getLogs(f: { fromBlock: number; toBlock: number }) {
      active++;
      peak = Math.max(peak, active);
      // Later ranges finish first, so ordering must come from the batch rather
      // than RPC completion timing.
      await new Promise((resolve) => setTimeout(resolve, f.fromBlock === 0 ? 8 : 1));
      active--;
      return [{
        address: ADDRESS,
        blockNumber: f.fromBlock,
        transactionHash: zeroPadValue(toBeHex(f.fromBlock + 1), 32),
        index: 0,
        ...iface.encodeEventLog('A', [f.fromBlock]),
      }];
    },
  };
  try {
    const c = new Contract(ADDRESS, ABI, provider as any);
    const out = await scanMany(c, ['A'], 0, 399);
    assert.deepEqual(out.map((e) => e.blockNumber), [0, 100, 200, 300]);
    assert.equal(peak, 4);
  } finally {
    if (previous === undefined) delete process.env.LOG_CONCURRENCY;
    else process.env.LOG_CONCURRENCY = previous;
  }
});

test('scanMany retries a dropped log request without restarting the scan', async () => {
  let calls = 0;
  const provider = {
    async getLogs(f: { fromBlock: number }) {
      calls++;
      if (calls === 1) throw new Error('socket hang up');
      return [{
        address: ADDRESS,
        blockNumber: f.fromBlock,
        transactionHash: zeroPadValue(toBeHex(f.fromBlock + 1), 32),
        index: 0,
        ...iface.encodeEventLog('A', [f.fromBlock]),
      }];
    },
  };
  const c = new Contract(ADDRESS, ABI, provider as any);
  const out = await scanMany(c, ['A'], 0, 99);
  assert.equal(calls, 2);
  assert.deepEqual(out.map((e) => e.blockNumber), [0]);
});

test('EventCache reads only the blocks it has not seen', async () => {
  const fake = fakeProvider([{ block: 5, name: 'A' }, { block: 60, name: 'B' }], 1000);
  const c = new Contract(ADDRESS, ABI, fake.provider as any);
  const cache = new EventCache();
  assert.equal((await cache.get('k', c, ['A', 'B'], 0, 50)).length, 1);
  const before = fake.calls.length;
  const all = await cache.get('k', c, ['A', 'B'], 0, 80);
  assert.equal(all.length, 2);
  assert.deepEqual(fake.calls.slice(before), [[51, 80]], 'the second pass scans only the new blocks');
  await cache.get('k', c, ['A', 'B'], 0, 80);
  assert.equal(fake.calls.length, before + 1, 'no request when the head has not moved');
});

test('semaphore bounds concurrent work and preserves input order', async () => {
  let active = 0;
  let peak = 0;
  const run = semaphore(3);
  const task = (i: number) =>
    run(async () => {
      active++;
      peak = Math.max(peak, active);
      await new Promise((r) => setTimeout(r, 5));
      active--;
      return i * 2;
    });
  const out = await Promise.all(Array.from({ length: 20 }, (_, i) => task(i)));
  assert.deepEqual(out, Array.from({ length: 20 }, (_, i) => i * 2), 'results keep their input order');
  assert.ok(peak <= 3, `never exceeds the bound, peaked at ${peak}`);
  assert.ok(peak >= 2, `does run in parallel, peaked at ${peak}`);
});

test('semaphore of size 1 serialises, and a failing task still releases its slot', async () => {
  const run = semaphore(1);
  const order: string[] = [];
  await assert.rejects(
    () => run(async () => { throw new Error('boom'); }),
    /boom/,
  );
  await Promise.all([
    run(async () => {
      order.push('a-start');
      await new Promise((r) => setTimeout(r, 5));
      order.push('a-end');
    }),
    run(async () => {
      order.push('b-start');
      order.push('b-end');
    }),
  ]);
  assert.deepEqual(order, ['a-start', 'a-end', 'b-start', 'b-end'], 'no overlap, and the throw did not wedge it');
});

test('retryTransient retries transport failures and gives up on a real revert', async () => {
  let transport = 0;
  const flaky = () =>
    retryTransient(async () => {
      transport++;
      if (transport < 3) throw new Error('Client network socket disconnected before secure TLS connection was established');
      return 'ok';
    }, 4, 1);
  assert.equal(await flaky(), 'ok');
  assert.equal(transport, 3, 'succeeded on the third attempt');

  let reverts = 0;
  await assert.rejects(
    () =>
      retryTransient(async () => {
        reverts++;
        throw new Error("execution reverted: custom error 'LimitExceeded()'");
      }, 4, 1),
    /LimitExceeded/,
  );
  assert.equal(reverts, 1, 'a deterministic revert is not retried');

  let timeouts = 0;
  await assert.rejects(
    () =>
      retryTransient(async () => {
        timeouts++;
        throw new Error('request timeout (code=TIMEOUT, version=6.16.0)');
      }, 3, 1),
    /timeout/,
  );
  assert.equal(timeouts, 3, 'a timeout is transient, so it exhausts the budget');
});
