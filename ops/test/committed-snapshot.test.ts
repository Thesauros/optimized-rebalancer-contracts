import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Interface, toBeHex, zeroPadValue } from 'ethers';
import { TICK_ACCOUNTANT } from '../src/abi';
import { Chain } from '../src/config';
import { committedSnapshot, Snapshot } from '../src/snapshot';

const iface = new Interface(TICK_ACCOUNTANT);
const address = '0x00000000000000000000000000000000000000aa';
const hash = (n: number) => zeroPadValue(toBeHex(n), 32);

for (const head of [350, 500]) {
  test(`committedSnapshot respects the 100-block RPC limit and head ${head}`, async () => {
    const snapshot: Snapshot = {
      version: 1, tickId: 7n, referenceTime: 1n,
      chains: [], positions: [], inFlight: [],
      hubCash: 1n, pendingDeposits: 0n, liabilities: 0n, totalShares: 1n,
    };
    const ranges: [number, number][] = [];
    const provider = {
      async call() {
        return iface.encodeFunctionResult('getTick', [[1, 2, 100, 1, 0, 1, 1, 1, 1, hash(7)]]);
      },
      async getBlockNumber() { return head; },
      async getLogs(filter: { fromBlock: number; toBlock: number }) {
        const { fromBlock, toBlock } = filter;
        assert.ok(toBlock <= head, 'must not request future blocks');
        if (toBlock - fromBlock + 1 > 100) {
          throw Object.assign(new Error('bad response'), {
            info: { responseBody: '{"code":400,"message":"Exceeded maximum block range: 100"}' },
          });
        }
        ranges.push([fromBlock, toBlock]);
        return [{ block: 110, tick: 6 }, { block: 320, tick: 7 }]
          .filter(({ block }) => block >= fromBlock && block <= toBlock)
          .map(({ block, tick }) => ({
            address, blockNumber: block, transactionHash: hash(tick), index: 0,
            ...iface.encodeEventLog('TickCommitted', [tick, 1, 0, 1, 100, 1, 1, 1, 1, hash(tick)]),
          }));
      },
      async getTransaction(txHash: string) {
        assert.equal(txHash, hash(7), 'must select the requested tick, not another event in the range');
        return { hash: txHash, data: iface.encodeFunctionData('commitTick', [snapshot, 0]) };
      },
    };
    const hub = { provider, manifest: { contracts: { TickAccountant: address } } } as unknown as Chain;
    const result = await committedSnapshot(hub, 7n);
    assert.deepEqual(result?.snapshot, snapshot);
    assert.equal(result?.block, 320);
    assert.equal(result?.txHash, hash(7));
    assert.equal(ranges[0][0], 100);
    assert.equal(ranges.at(-1)?.[1], Math.min(head, 400));
    for (let i = 1; i < ranges.length; i++) assert.equal(ranges[i][0], ranges[i - 1][1] + 1);
  });
}
