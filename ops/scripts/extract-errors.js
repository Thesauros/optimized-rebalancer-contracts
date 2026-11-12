// Writes src/errors.json: the custom errors of the compiled contracts, taken from
// the hardhat artifacts. Committed, because artifacts/ is not, and the operator
// CLI on the server needs it to name a revert (src/exec.ts). Re-run after changing
// a contract's errors (`npx hardhat compile` first); test/abi.test.ts fails on drift.
//
// Walks artifacts/contracts instead of listing files. A hardcoded list went stale
// once already and errors.json shipped without any Timelock__* selector, so `exec`
// could not name a revert from the contract operators queue through most. Walking
// the tree needs no edit when a contract is added.
/* Shared by the ABI regression test and operator error decoding. */
const fs = require('node:fs');
const path = require('node:path');
const { Fragment } = require('ethers');

function extract() {
  const root = path.resolve(__dirname, '../../artifacts/contracts');
  const errors = new Map();
  function visit(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name);
      if (fs.statSync(file).isDirectory()) visit(file);
      else if (name.endsWith('.json') && !name.endsWith('.dbg.json')) {
        const abi = JSON.parse(fs.readFileSync(file, 'utf8')).abi ?? [];
        for (const entry of abi) if (entry.type === 'error') errors.set(Fragment.from(entry).format('sighash'), entry);
      }
    }
  }
  visit(root);
  return [...errors.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, error]) => error);
}

module.exports = { extract };
if (require.main === module) {
  const out = path.resolve(__dirname, '../src/errors.json');
  fs.writeFileSync(out, JSON.stringify(extract(), null, 1) + '\n');
  console.log(`wrote ${out}`);
}
