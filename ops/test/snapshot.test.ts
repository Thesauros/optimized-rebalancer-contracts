import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, keccak256, zeroPadValue, toBeHex } from 'ethers';
import { Snapshot, TransferIndex, consistentCut, hashSnapshot, sortPositions, totals } from '../src/snapshot';
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
