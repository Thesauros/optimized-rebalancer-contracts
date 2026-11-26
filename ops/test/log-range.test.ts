import test from 'node:test';
import assert from 'node:assert/strict';
import { logStepFor, providerRangeLimit, scanMany } from '../src/util';

/** Real rejection texts, copied from the endpoints rather than invented. */
const PLASMA_RANGE = 'eth_getLogs is limited to a 10,000 range';
const PLASMA_RESULTS = 'query exceeds max results 20000, retry with the range 38404248-38414248';
const MORALIS = 'block range too large';
const MAX_RANGE = 'Exceeded maximum block range: 100';

test('providerRangeLimit reads a ceiling stated before the word "range"', () => {
  assert.equal(providerRangeLimit(new Error(PLASMA_RANGE)), 9999);
  // The same endpoint states the ceiling as an HTTP 413 body too.
  assert.equal(providerRangeLimit({ info: { responseBody: PLASMA_RANGE } }), 9999);
});

test('providerRangeLimit halves on a results ceiling instead of adopting its block number', () => {
  // 38404248 is a block number in the suggested retry range, not the limit.
  // Reading it as one yields a step far larger than any span, which used to
  // fall through to halving by accident; 0 now means halve deliberately.
  assert.equal(providerRangeLimit(new Error(PLASMA_RESULTS)), 0);
});

test('providerRangeLimit keeps the ceilings it already understood', () => {
  assert.equal(providerRangeLimit(new Error(MORALIS)), 0, 'no digits stated: halve');
  assert.equal(providerRangeLimit(new Error(MAX_RANGE)), 99, 'digits after the word');
});

test('providerRangeLimit never shrinks on throttling, head lag or unrelated errors', () => {
  for (const text of [
    '429 Too Many Requests',
    'Public endpoint rate limit',
    'Rate limit exceeded',
    'retry limit exceeded',
    'quota exceeded for this key',
    'maximum compute units per second reached',
    'block range extends beyond current head',
    'block range extends beyond current head block',
    'execution reverted: no data',
    'missing trie node 0xdeadbeef',
  ]) {
    assert.equal(providerRangeLimit(new Error(text)), undefined, text);
  }
});

/** Minimal Contract + Provider double that rejects ranges wider than `cap`. */
function fakeContract(cap: number, provider: object) {
  const seen: { fromBlock: number; toBlock: number }[] = [];
  const contract = {
    interface: {
      getEvent: () => ({ topicHash: '0x' + '11'.repeat(32) }),
      parseLog: () => null,
    },
    getAddress: async () => '0x' + '22'.repeat(20),
    runner: { provider },
    seen,
  };
  const wrapped = {
    ...provider,
    getLogs: async (filter: { fromBlock: number; toBlock: number }) => {
      seen.push({ fromBlock: filter.fromBlock, toBlock: filter.toBlock });
      if (filter.toBlock - filter.fromBlock + 1 > cap) throw new Error(`eth_getLogs is limited to a ${cap.toLocaleString('en-US')} range`);
      return [];
    },
  };
  contract.runner = { provider: wrapped };
  return { contract: contract as any, provider: wrapped, seen };
}

test('one chain hitting its range cap does not shrink another chain in the same process', async () => {
  // Monad's public RPC caps eth_getLogs at about 101 blocks; Base and Arbitrum
  // serve thousands. With one module-global step the Monad cap used to drag the
  // others down to ~100 blocks per request for the rest of the process.
  const monad = fakeContract(101, {});
  const base = fakeContract(9001, {});

  await scanMany(monad.contract, ['Sent'], 0, 1000);
  assert.ok(logStepFor(monad.provider) <= 101, 'Monad learned its own ceiling');
  assert.equal(logStepFor(base.provider), 9000, 'an untouched chain keeps the configured step');

  await scanMany(base.contract, ['Sent'], 0, 1000);
  const spans = base.seen.map((s) => s.toBlock - s.fromBlock + 1);
  assert.equal(Math.max(...spans), 1001, 'Base still scans in wide ranges');
  assert.equal(base.seen.length, 1, 'and needed exactly one request for 1001 blocks');
});

test('a learned ceiling persists for that provider across calls', async () => {
  const monad = fakeContract(101, {});
  await scanMany(monad.contract, ['Sent'], 0, 5000);
  const learned = logStepFor(monad.provider);
  assert.ok(learned > 0 && learned <= 101, `learned ${learned}`);
  monad.seen.length = 0;

  await scanMany(monad.contract, ['Sent'], 0, 5000);
  const spans = monad.seen.map((s) => s.toBlock - s.fromBlock + 1);
  assert.ok(Math.max(...spans) <= 101, 'no request re-attempts a rejected width');
});
