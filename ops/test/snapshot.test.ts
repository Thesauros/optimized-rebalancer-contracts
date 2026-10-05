import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { AbiCoder, keccak256, zeroPadValue, toBeHex } from 'ethers';
import { Snapshot, TransferIndex, openTransferIndex, consistentCut, hashSnapshot, sortPositions, totals } from '../src/snapshot';
import { transferIdOf, sourceDomainOf } from '../src/cctp';

const b32 = (n: number) => zeroPadValue(toBeHex(n), 32);
const addr = (n: number) => zeroPadValue(toBeHex(n), 20);

/** Same vector as test/tick/SnapshotVector.t.sol. */
export const VECTOR: Snapshot = {
  version: 1,
  tickId: 7n,
  referenceTime: 1_800_000_000n,
  chains: [
    { chainId: 8453n, blockNumber: 30_000_000n, blockHash: b32(0xb1) },
    { chainId: 42161n, blockNumber: 250_000_000n, blockHash: b32(0xa1) },
  ],
  positions: [
    { chainId: 8453n, holder: addr(0x1111), strategy: addr(0), kind: 0, units: 5_000_000n, valueBid: 5_000_000n, valueOffer: 5_000_000n },
    { chainId: 42161n, holder: addr(0x2222), strategy: addr(0x3333), kind: 1, units: 9_000_000n, valueBid: 10_000_000n, valueOffer: 10_000_000n },
  ],
  inFlight: [{ transferId: b32(0xfeed), srcChainId: 8453n, dstChainId: 42161n, sentAt: 1_799_999_000n, amountSent: 3_000_000n, minReceive: 2_990_000n, writtenDown: 0n }],
  hubCash: 1_000_000n,
  pendingDeposits: 200_000n,
  liabilities: 100_000n,
  totalShares: 18_000_000n,
};

test('TS snapshot hash equals the Solidity keccak256(abi.encode(snapshot))', () => {
  assert.equal(hashSnapshot(VECTOR), '0xcb6fb2dc96d2af5a545b88e19827738167ff81c6f8b7447ec490b6fb341e71b5');
});

test('totals mirror NavSnapshot.totals and the gross rates', () => {
  const t = totals(VECTOR, 3600n);
  // bid: 1.0 + 5.0 + 10.0 + min(2.99, 3.0) - 0.2 - 0.1 = 18.69
  assert.equal(t.navBid, 18_690_000n);
  assert.equal(t.navOffer, 18_700_000n);
  assert.equal(t.inFlight, 3_000_000n);
  assert.equal(t.overdueInFlight, 0n);
  assert.equal(t.grossBid, (18_690_000n * 10n ** 18n) / 18_000_000n);
});

test('positions sort strictly by (chainId, holder, strategy, kind)', () => {
  const shuffled = [VECTOR.positions[1], VECTOR.positions[0]];
  assert.deepEqual(sortPositions(shuffled), VECTOR.positions);
});

function indexWith(sent: [string, string, number][], received: [string, string, number][]): TransferIndex {
  const i = new TransferIndex();
  for (const [id, chain, block] of sent) i.sent.set(id, { transferId: id, chainKey: chain, block, txHash: '0x', amount: 1n, dstChainId: 0n, minReceive: 1n });
  for (const [id, chain, block] of received) i.received.set(id, { transferId: id, chainKey: chain, block, txHash: '0x', amount: 1n });
  return i;
}

test('consistent cut advances a source ref to cover every receipt inside the cut', () => {
  const idx = indexWith([['0x01', 'base', 120]], [['0x01', 'arbitrum', 55]]);
  const cut = consistentCut(new Map([['base', 100], ['arbitrum', 60]]), idx);
  assert.equal(cut.get('base'), 120, 'base advanced to the BridgeOut block');
  assert.equal(cut.get('arbitrum'), 60);
});

test('consistent cut leaves a consistent cut untouched and iterates to a fixpoint', () => {
  const idx = indexWith(
    [['0x01', 'base', 90], ['0x02', 'arbitrum', 70]],
    [['0x01', 'arbitrum', 50], ['0x02', 'base', 110]],
  );
  // arbitrum receipt of 0x01 at 50 is covered (sent at 90 <= 100); 0x02 received at 110 > 100: not in cut
  const cut = consistentCut(new Map([['base', 100], ['arbitrum', 60]]), idx);
  assert.deepEqual([...cut], [['base', 100], ['arbitrum', 60]]);
  // chain reaction: advancing base to 110 pulls in the receipt of 0x02, whose send (70) needs arbitrum >= 70
  const idx2 = indexWith([['0x01', 'base', 110], ['0x02', 'arbitrum', 70]], [['0x01', 'arbitrum', 50], ['0x02', 'base', 105]]);
  const cut2 = consistentCut(new Map([['base', 100], ['arbitrum', 60]]), idx2);
  assert.equal(cut2.get('base'), 110);
  assert.equal(cut2.get('arbitrum'), 70);
});

test('consistent cut never references a block above its confirmation depth', () => {
  // receipt of 0x01 is inside the arbitrum cut, but its BridgeOut on base sits
  // above base's confirmed head, so it cannot be advanced to
  const idx = indexWith([['0x01', 'base', 120]], [['0x01', 'arbitrum', 55]]);
  const refs = new Map([['base', 100], ['arbitrum', 60]]);
  const ceilings = new Map([['base', 100], ['arbitrum', 60]]);

  assert.equal(consistentCut(new Map(refs), idx).get('base'), 120, 'without a ceiling the source ref is pushed to an unconfirmed block');

  const cut = consistentCut(refs, idx, ceilings);
  assert.equal(cut.get('base'), 100, 'the source ref stays at its confirmed depth');
  assert.equal(cut.get('arbitrum'), 54, 'the receipt leaves the cut instead, so the transfer stays in flight');
});

test('consistent cut terminates when a dropped receipt would be re-pulled by another transfer', () => {
  // 0x01 base@120 (above base's ceiling) -> arbitrum@55, so arbitrum drops to 54.
  // 0x02 arbitrum@58 -> base@90 then asks to advance arbitrum to 58, which would
  // re-include 0x01's receipt; without the lowered ceiling this oscillates forever.
  // (Causally impossible on honest chains, but a reorged or lying RPC can serve it.)
  const idx = indexWith([['0x01', 'base', 120], ['0x02', 'arbitrum', 58]], [['0x01', 'arbitrum', 55], ['0x02', 'base', 90]]);
  const cut = consistentCut(new Map([['base', 100], ['arbitrum', 60]]), idx, new Map([['base', 100], ['arbitrum', 60]]));
  assert.equal(cut.get('arbitrum'), 54);
  assert.equal(cut.get('base'), 89, 'the receipt of 0x02 leaves the cut too, since its send is now above the cut');
});

test('transfer index persists across restarts and rejects state from another deployment', async () => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), 'transfer-index-')), 'index.json');
  const a = new TransferIndex(file, 'fp-1');
  a.sent.set('0x01', { transferId: '0x01', chainKey: 'base', block: 120, txHash: '0xaa', amount: 5n, dstChainId: 42161n, minReceive: 4n });
  a.received.set('0x01', { transferId: '0x01', chainKey: 'arbitrum', block: 55, txHash: '0xbb', amount: 4n });
  await a.save();

  const b = new TransferIndex(file, 'fp-1');
  await b.load();
  assert.equal(b.sent.get('0x01')?.amount, 5n, 'bigint survives the round trip');
  assert.equal(b.sent.get('0x01')?.dstChainId, 42161n);
  assert.equal(b.received.get('0x01')?.block, 55);

  const c = new TransferIndex(file, 'fp-other');
  await c.load();
  assert.equal(c.sent.size, 0, 'state written by a different deployment is discarded');
});

test('CCTP helpers read our hookData and the source domain from a V2 message', () => {
  const header = new Uint8Array(148);
  header.set([0, 0, 0, 1], 0); // version
  header.set([0, 0, 0, 6], 4); // source domain = Base
  const body = new Uint8Array(228);
  const hook = AbiCoder.defaultAbiCoder().encode(['bytes32', 'address'], [keccak256('0x1234'), addr(0xabc)]);
  const msg = '0x' + Buffer.from(header).toString('hex') + Buffer.from(body).toString('hex') + hook.slice(2);
  assert.equal(transferIdOf(msg), keccak256('0x1234'));
  assert.equal(sourceDomainOf(msg), 6);
});


test('shared transfer scans checkpoint completed pages and resume after failure', async () => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), 'transfer-resume-')), 'index.json');
  const calls: number[] = [];
  let fail = true;
  const chain: any = {
    key: 'base', chainId: 8453n, manifest: { startBlock: 1, contracts: { ChainAgent: addr(1) } },
    provider: {
      getBlockNumber: async () => 300,
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: number; toBlock: number }) => {
        if (toBlock - fromBlock >= 100) throw new Error('Exceeded maximum block range: 100');
        calls.push(fromBlock);
        if (fail && fromBlock >= 101) throw new Error('upstream unavailable');
        return [];
      },
    },
  };
  const [a, b] = await Promise.all([openTransferIndex([chain], file), openTransferIndex([chain], file)]);
  assert.equal(a, b, 'operators share one index and one sync lock');
  await assert.rejects(a.sync([chain]));
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).scanned.base, 100);
  fail = false;
  calls.length = 0;
  await Promise.all([a.sync([chain]), b.sync([chain])]);
  assert.deepEqual(calls, [101, 201], 'no duplicate scan by concurrent consumers');
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).scanned.base, 300);
});
