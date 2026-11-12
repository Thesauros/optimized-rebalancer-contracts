'use strict';
// Public chain observations only. No production keys, signing or writes.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers'))
  ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const E = require(path.join(deps, 'ops/node_modules/ethers'));
const m = JSON.parse(fs.readFileSync(path.join(root, 'deployments/base/crosschain.json')));
const abi = new E.Interface([
  'function latestAccepted() view returns(uint64,(uint64,uint64,uint64,uint8,uint8,uint128,uint128,uint128,uint128,bytes32))',
  'event TickCommitted(uint64 indexed tickId,uint8 status,uint8 flags,uint64 referenceTime,uint64 hubBlock,uint256 rateBid,uint256 rateOffer,uint256 navBid,uint256 navOffer,bytes32 navHash)',
]);
class ReadOnly extends E.JsonRpcProvider {
  async send(method, params) {
    assert.ok(['eth_chainId', 'eth_call', 'eth_getBlockByNumber', 'eth_getBalance', 'eth_gasPrice',
      'eth_getLogs', 'eth_getTransactionByHash', 'eth_getTransactionReceipt'].includes(method), 'public write prohibited');
    console.log(JSON.stringify({ stage: 'read-only NAV observation', method }));
    return super.send(method, params);
  }
}
async function main() {
  const secondary = process.argv[2] === 'secondary';
  assert.ok(process.argv.length <= 3 && (!process.argv[2] || secondary), 'unsupported mode');
  const request = new E.FetchRequest(secondary ? 'https://base-rpc.publicnode.com' : 'https://mainnet.base.org');
  request.timeout = 30000;
  const rpc = new ReadOnly(request, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  try {
    assert.equal(BigInt(await rpc.send('eth_chainId', [])), 8453n);
    const head = await rpc.send('eth_getBlockByNumber', ['latest', false]);
    const [id, tick] = abi.decodeFunctionResult('latestAccepted', await rpc.send('eth_call', [
      { to: m.contracts.TickAccountant, data: abi.encodeFunctionData('latestAccepted') }, head.number]));
    // The current tick was committed nine seconds after its hub reference.
    // Keep this lookup bounded; broad scans on public RPCs can time out.
    const upper = tick[2] + 500n < BigInt(head.number) ? tick[2] + 500n : BigInt(head.number);
    const logs = await rpc.send('eth_getLogs', [{ address: m.contracts.TickAccountant,
      topics: [abi.getEvent('TickCommitted').topicHash, E.toBeHex(id, 32)],
      fromBlock: E.toQuantity(tick[2]), toBlock: E.toQuantity(upper) }]);
    assert.equal(logs.length, 1, 'could not uniquely locate latest accepted NAV transaction');
    const hash = logs[0].transactionHash;
    const [transaction, receipt, price] = await Promise.all([
      rpc.send('eth_getTransactionByHash', [hash]), rpc.send('eth_getTransactionReceipt', [hash]),
      rpc.send('eth_gasPrice', []),
    ]);
    assert.equal(BigInt(receipt.status), 1n);
    const balance = BigInt(await rpc.send('eth_getBalance', [transaction.from, head.number]));
    const lastGas = BigInt(receipt.gasUsed), l1 = BigInt(receipt.l1Fee || '0x0');
    const record = { chainId: 8453, rpc: secondary ? 'Base PublicNode' : 'Base public RPC', productionWrites: false,
      observedBlock: Number(BigInt(head.number)), observedAtUtc: new Date(Number(BigInt(head.timestamp)) * 1000).toISOString(),
      tickId: id.toString(), referenceTimeUtc: new Date(Number(tick[0]) * 1000).toISOString(),
      committedAtUtc: new Date(Number(tick[1]) * 1000).toISOString(),
      committedAgeSeconds: (BigInt(head.timestamp) - tick[1]).toString(),
      transactionHash: hash, sender: transaction.from, gasUsed: lastGas.toString(),
      lastExecutionFeeWei: (lastGas * BigInt(receipt.effectiveGasPrice)).toString(), lastL1FeeWei: l1.toString(),
      senderCurrentBalanceWei: balance.toString(), senderCurrentBalanceEth: E.formatEther(balance),
      currentGasPriceWei: BigInt(price).toString(),
      sameGasExecutionQuoteWei: (lastGas * BigInt(price)).toString(),
      balanceCoversSameGasExecutionOnly: balance >= lastGas * BigInt(price),
      limitation: 'A gas quote is not a new commit simulation. Remote process state, pending transactions, RPC failures and actual cause require server logs.' };
    fs.writeFileSync(path.join(__dirname, 'live-nav-verification.json'), JSON.stringify(record, null, 2) + '\n');
    console.log(JSON.stringify(record, null, 2));
  } finally { rpc.destroy(); }
}
main().catch(e => {
  console.error('Live NAV read failed: ' + (e.code || 'error') + ': ' +
    String(e?.info?.error?.message || e.shortMessage || e.message).replace(/https?:\/\/[^\s"']+/g, '[RPC]').slice(0, 400));
  process.exitCode = 1;
});
