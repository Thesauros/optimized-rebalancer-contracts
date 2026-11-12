import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, Interface, keccak256 } from 'ethers';
import {
  buildPlan, DELAY, GRACE, Observation, OWNER, planState, ReadOnlyProvider,
  SIGNATURE, targetLimits, TIMELOCK, timelockAbi, validatePlan, VAULT,
} from '../src/prepare-buffer-10pct';

const observed: Observation = {
  blockNumber: 53251875, blockHash: `0x${'12'.repeat(32)}`, timestamp: 1793293097,
  before: ['1000000', '500000000', '5000000', '100000000000000000', '25000000', '50000000', '2500000000000000', '7200'],
  oldQueued: true,
};
const eta = observed.timestamp + DELAY + 6 * 3600;
const make = () => buildPlan(observed, eta);

test('10% proposal changes only the fixed floor; preserves seven fields without mutating input', () => {
  const original = [...observed.before];
  const after = targetLimits(observed.before);
  assert.deepEqual(observed.before, original);
  assert.equal(after[2], '0');
  for (let i = 0; i < 8; i++) if (i !== 2) assert.equal(after[i], original[i]);
  assert.throws(() => targetLimits([]), /tuple/);
  for (const value of ['-1', '1e6', '01', (1n << 128n).toString()]) {
    assert.throws(() => targetLimits([value, ...original.slice(1)]), /tuple/);
  }
  assert.throws(() => targetLimits([...original.slice(0, 7), (1n << 64n).toString()]), /tuple/);
  const differentRatio = [...original]; differentRatio[3] = '50000000000000000';
  assert.throws(() => targetLimits(differentRatio), /changed policy/);
  const alreadyApplied = [...original]; alreadyApplied[2] = '0';
  assert.throws(() => targetLimits(alreadyApplied), /changed policy/);
});

test('both unsigned requests decode to the same exact Timelock operation; no ETH or allocation', () => {
  const plan = make();
  const target = new Interface([`function ${SIGNATURE}`]);
  assert.deepEqual(Array.from(target.decodeFunctionData('setLimits', plan.targetCalldata)[0], String), plan.after);
  assert.equal(plan.data, `0x${plan.targetCalldata.slice(10)}`);
  assert.equal(plan.id, keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], [VAULT, 0, SIGNATURE, plan.data, eta],
  )));
  assert.deepEqual(Object.keys(plan.transactions), ['queue', 'execute']);
  for (const method of ['queue', 'execute'] as const) {
    const tx = plan.transactions[method];
    assert.deepEqual({ chainId: tx.chainId, from: tx.from, to: tx.to, value: tx.value },
      { chainId: 8453, from: OWNER, to: TIMELOCK, value: '0' });
    const args = timelockAbi.decodeFunctionData(method, tx.data);
    assert.deepEqual(Array.from(args), [VAULT, 0n, SIGNATURE, plan.data, BigInt(eta)]);
  }
  assert.equal(plan.queueInclusionDeadline, eta - DELAY);
  assert.equal(plan.executionDeadline, eta + GRACE);
  assert.equal(plan.old5pctOperation.expiredAtObservation, true);
  validatePlan(plan);
});

test('reject invalid observations/ETA and tampered public plans', () => {
  assert.throws(() => buildPlan(observed, observed.timestamp + DELAY - 1), /ETA/);
  assert.throws(() => buildPlan(observed, Number.MAX_SAFE_INTEGER), /ETA/);
  assert.throws(() => buildPlan({ ...observed, blockHash: '0x00' }, eta), /observation/);
  for (const field of ['id', 'data', 'targetCalldata', 'vault', 'owner', 'timelock', 'etaUtc'] as const) {
    const plan = make(); plan[field] = 'altered';
    assert.throws(() => validatePlan(plan), /altered/);
  }
  for (const field of ['eta', 'chainId', 'delaySeconds', 'queueInclusionDeadline', 'executionDeadline'] as const) {
    const plan = make(); plan[field]++;
    assert.throws(() => validatePlan(plan), /altered/);
  }
  const modifiedLimit = make(); modifiedLimit.after[5] = '999';
  assert.throws(() => validatePlan(modifiedLimit), /altered/);
  const modifiedTx = make(); modifiedTx.transactions.execute.value = '1';
  assert.throws(() => validatePlan(modifiedTx), /altered/);
});

test('check fails closed on drift and observes queue, timing and completion boundaries', () => {
  const plan = make();
  assert.equal(planState(plan, observed, false), 'ready_to_queue');
  assert.equal(planState(plan, { ...observed, timestamp: eta - DELAY }, false), 'ready_to_queue');
  assert.equal(planState(plan, { ...observed, timestamp: eta - DELAY + 1 }, false), 'missed_queue_window');
  assert.equal(planState(plan, observed, true), 'queued_waiting');
  assert.equal(planState(plan, { ...observed, timestamp: eta }, true), 'ready_to_execute');
  assert.equal(planState(plan, { ...observed, timestamp: eta + GRACE }, true), 'ready_to_execute');
  assert.equal(planState(plan, { ...observed, timestamp: eta + GRACE + 1 }, true), 'expired');
  assert.equal(planState(plan, { ...observed, before: plan.after }, false), 'target_already_applied');
  assert.throws(() => planState(plan, { ...observed, before: ['999', ...observed.before.slice(1)] }, true), /DO NOT sign/);
});

test('read-only provider rejects signing, broadcasting and node mutation before network access', async () => {
  const provider = new ReadOnlyProvider('http://127.0.0.1:1');
  try {
    for (const method of ['eth_sendTransaction', 'eth_sendRawTransaction', 'eth_sign',
      'personal_sign', 'eth_signTypedData_v4', 'personal_unlockAccount', 'evm_mine', 'anvil_setStorageAt']) {
      await assert.rejects(provider.send(method, []), /RPC method prohibited/);
    }
  } finally { provider.destroy(); }
});
