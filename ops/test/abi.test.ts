/**
 * Guards ops/src/abi.ts against drift from the contracts: every human-readable
 * fragment must exist, with the same inputs and outputs, in the compiled
 * artifact ABI. Needs `npx hardhat compile` (artifacts/) to have run.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import path from 'path';
import { Fragment, Interface } from 'ethers';
import { ADAPTER, CHAIN_AGENT, EPOCH_VAULT, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from '../src/abi';

const artifacts = path.join(__dirname, '..', '..', 'artifacts', 'contracts');
const load = (rel: string) => new Interface(JSON.parse(fs.readFileSync(path.join(artifacts, rel), 'utf8')).abi);

const cases: [string, string[], string][] = [
  ['TickAccountant', TICK_ACCOUNTANT, 'tick/TickAccountant.sol/TickAccountant.json'],
  ['EpochVault', EPOCH_VAULT, 'tick/EpochVault.sol/EpochVault.json'],
  ['ChainAgent', CHAIN_AGENT, 'crosschain/ChainAgent.sol/ChainAgent.json'],
  ['Rebalancer', STRATEGY, 'Rebalancer.sol/Rebalancer.json'],
  ['CctpV2Adapter', ADAPTER, 'crosschain/bridges/CctpV2Adapter.sol/CctpV2Adapter.json'],
  ['Timelock', TIMELOCK, 'access/Timelock.sol/Timelock.json'],
];

for (const [name, abi, rel] of cases) {
  test(`${name}: ops ABI fragments match the compiled artifact`, (t) => {
    if (!fs.existsSync(path.join(artifacts, rel))) return t.skip('run `npx hardhat compile` first');
    const artifact = load(rel);
    for (const human of abi) {
      const f = Fragment.from(human);
      if (f.type === 'function') {
        const a = artifact.getFunction((f as any).format('sighash'));
        assert.ok(a, `${name}: missing function ${(f as any).format('sighash')}`);
        assert.equal(a!.format('minimal'), (f as any).format('minimal'), `${name}: ${(f as any).format('sighash')} differs (types, mutability or outputs)`);
      } else if (f.type === 'event') {
        const a = artifact.getEvent((f as any).format('sighash'));
        assert.ok(a, `${name}: missing event ${(f as any).format('sighash')}`);
        assert.equal(a!.format('minimal'), (f as any).format('minimal'), `${name}: event ${(f as any).format('sighash')} indexing differs`);
      }
    }
  });
}
