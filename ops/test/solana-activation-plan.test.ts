import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Interface, type JsonRpcProvider, ZeroAddress } from 'ethers';
import { SOLANA } from '../../deploy/crosschain/native-registry';
import { NETWORKS } from '../../deploy/crosschain/registry';
import { CHAIN_AGENT, TICK_ACCOUNTANT } from '../src/abi';
import { loadManifest, type Chain } from '../src/config';
import { planHubActivation } from '../src/solana/plan';

const nativeId = SOLANA.accountingId;
const base = loadManifest('base');
const native = { hubAgent: base.contracts.ChainAgent, hubAdapter: '0x0000000000000000000000000000000000000001' };
const alias = '0x0000000000000000000000000000000000000002';
const limits = { maxFeeBps: 5, maxPerTransfer: '1000000', capacity: '5000000', refillPerSecond: '10' };
const accountantAbi = new Interface([...TICK_ACCOUNTANT, 'function setChains(uint64[])', 'function setAgent(uint64,address,bool)']);
const agentAbi = new Interface(CHAIN_AGENT);
const registeredRoute = [native.hubAdapter, nativeId, alias, 5n, true, 1000000n, 5000000n, 10n, 1000n, 20n];

function hubFixture({
  chainIds = [1n, 8453n, 42161n], adapter = false, peer = false, allowed = false, route = [],
}: { chainIds?: bigint[]; adapter?: boolean; peer?: boolean; allowed?: boolean; route?: (string | bigint | boolean)[] } = {}): Chain {
  const provider = {
    getBlockNumber: async () => 800,
    call: async (tx: { to: string; data: string; blockTag: number }) => {
      assert.equal(tx.blockTag, 800);
      const abi = tx.to === base.contracts.TickAccountant ? accountantAbi : agentAbi;
      const call = abi.parseTransaction(tx)!;
      let result;
      switch (call.name) {
        case 'chainIds': result = chainIds; break;
        case 'isAdapter':
          assert.equal(call.args[0], native.hubAdapter);
          result = adapter;
          break;
        case 'isPeer':
        case 'isAgent':
          assert.deepEqual([...call.args], [nativeId, alias]);
          result = call.name === 'isPeer' ? peer : allowed;
          break;
        case 'getRoute': result = route.length ? route : [ZeroAddress, 0n, ZeroAddress, 0n, false, 0n, 0n, 0n, 0n, 0n]; break;
        default: throw Error(`unexpected Base read ${call.name}`);
      }
      return abi.encodeFunctionResult(call.name, [result]);
    },
  } as unknown as JsonRpcProvider;
  return { key: 'base', chainId: NETWORKS.base.chainId, entry: NETWORKS.base, manifest: base, provider };
}

test('new Solana activation installs the route and preserves every tracked chain before authorizing the agent', async () => {
  const plan = await planHubActivation(hubFixture(), native, alias, limits);
  assert.deepEqual(plan.actions.map((a) => a.label), [
    'ChainAgent.setAdapter', 'ChainAgent.setPeer', 'ChainAgent.addRoute', 'TickAccountant.setChains', 'TickAccountant.setAgent',
  ]);
  const [membership, permission] = plan.actions.slice(-2);
  assert.equal(membership.target, base.contracts.TickAccountant);
  assert.equal(permission.target, membership.target);
  assert.deepEqual([...accountantAbi.decodeFunctionData('setChains', membership.data)[0]], [1n, 8453n, 42161n, nativeId]);
  assert.deepEqual([...accountantAbi.decodeFunctionData('setAgent', permission.data)], [nativeId, alias, true]);
});

test('activation resumes with outstanding actions only and finishes with an empty plan', async () => {
  const prior = { adapter: true, peer: true, chainIds: [8453n, 42161n, nativeId], route: registeredRoute };
  const partial = await planHubActivation(hubFixture(prior), native, alias, limits);
  assert.deepEqual(partial.actions.map((a) => a.label), ['TickAccountant.setAgent']);
  const finished = await planHubActivation(hubFixture({ ...prior, allowed: true }), native, alias, limits);
  assert.deepEqual(finished.actions, []);
});

test('activation refuses an existing route with different endpoints, limits or pause state', async () => {
  for (const [index, value] of [[0, alias], [1, 42161n], [2, native.hubAdapter], [4, false], [6, 2000000n]] as const) {
    const route = registeredRoute.slice();
    route[index] = value;
    await assert.rejects(planHubActivation(hubFixture({ route }), native, alias, limits), /Existing Base-to-Solana route differs/);
  }
});

test('Base cannot propose limits that the Solana route cannot store', async () => {
  const overflow = (1n << 64n).toString();
  for (const invalid of [
    { maxFeeBps: 10000 }, { maxFeeBps: -1 }, { maxFeeBps: 1.25 }, { maxPerTransfer: '0' }, { capacity: '1' },
    { maxPerTransfer: overflow }, { capacity: overflow }, { refillPerSecond: overflow }, { refillPerSecond: '-1' },
    { maxPerTransfer: '1e6' }, { capacity: '5.5' }, { refillPerSecond: (Number.MAX_SAFE_INTEGER + 1) as unknown as string },
  ]) {
    await assert.rejects(planHubActivation(hubFixture(), native, alias, { ...limits, ...invalid }), /limit|micro-units/);
  }
  const highest = ((1n << 64n) - 1n).toString();
  await planHubActivation(hubFixture(), native, alias, { maxFeeBps: 9999, maxPerTransfer: highest, capacity: highest, refillPerSecond: '0' });
});
