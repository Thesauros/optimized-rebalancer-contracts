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
if (require.main === module)
  fs.writeFileSync(path.resolve(__dirname, '../src/errors.json'), JSON.stringify(extract(), null, 1) + '\n');
