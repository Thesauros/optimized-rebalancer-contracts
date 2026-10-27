// Writes src/errors.json: the custom errors of the cross-chain contracts, taken
// from the hardhat artifacts. Committed, because artifacts/ is not, and the
// operator CLI on the server needs it to name a revert. Re-run after changing a
// contract's errors (`npx hardhat compile` first); test/abi.test.ts fails on drift.
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..', '..', 'artifacts', 'contracts');
const FILES = [
  'crosschain/ChainAgent.sol/ChainAgent.json',
  'crosschain/bridges/CctpV2Adapter.sol/CctpV2Adapter.json',
  'tick/EpochVault.sol/EpochVault.json',
  'tick/EpochVaultLogic.sol/EpochVaultLogic.json',
  'tick/TickAccountant.sol/TickAccountant.json',
  'Rebalancer.sol/Rebalancer.json',
];
function extract() {
  const seen = new Map();
  for (const f of FILES) {
    for (const e of JSON.parse(fs.readFileSync(path.join(root, f), 'utf8')).abi) {
      if (e.type === 'error') seen.set(`${e.name}(${e.inputs.map((i) => i.type).join(',')})`, e);
    }
  }
  return [...seen.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, e]) => e);
}
module.exports = { extract };
if (require.main === module) {
  const out = path.join(__dirname, '..', 'src', 'errors.json');
  fs.writeFileSync(out, JSON.stringify(extract(), null, 1) + '\n');
  console.log(`wrote ${out}`);
}
