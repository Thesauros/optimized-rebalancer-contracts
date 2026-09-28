import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Contract, Interface, zeroPadValue, toBeHex } from 'ethers';
import { EventCache, scanMany } from '../src/util';

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
