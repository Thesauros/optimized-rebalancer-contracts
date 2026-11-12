import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, Interface, keccak256 } from 'ethers';
import { bufferLimits, validatePlan } from '../src/buffer-governance';

test('buffer change preserves all six unrelated limits and the original tuple', () => {
  const before = ['1000000', '500000000', '5000000', '100000000000000000', '25000000', '50000000', '2500000000000000', '7200'];
  const after = bufferLimits(before);
  assert.deepEqual(after, ['1000000', '500000000', '0', '50000000000000000', '25000000', '50000000', '2500000000000000', '7200']);
  assert.equal(before[2], '5000000');
  assert.throws(() => bufferLimits([]), /limits shape/);
});

test('a queued plan cannot change another limit, the target, or its execution time', () => {
  const before = ['1000000', '500000000', '5000000', '100000000000000000', '25000000', '50000000', '2500000000000000', '7200'];
  const signature = 'setLimits((uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64))';
  const vault = '0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6';
  const timelock = '0x540cAab5492014084502c1dB6F15644eedCa87ee';
  const after = bufferLimits(before);
  const data = '0x' + new Interface([`function ${signature}`]).encodeFunctionData('setLimits', [after]).slice(10);
  const eta = 1791237600;
  const id = keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], [vault, 0, signature, data, eta],
  ));
  const plan = { chainId: '8453', vault, timelock, before, after, data, eta, id, txs: {} };
  validatePlan(plan, timelock);
  assert.throws(() => validatePlan({ ...plan, after: ['2', ...after.slice(1)] }, timelock), /altered/);
  assert.throws(() => validatePlan({ ...plan, vault: timelock }, timelock), /altered/);
  assert.throws(() => validatePlan({ ...plan, eta: eta + 1 }, timelock), /altered/);
});
