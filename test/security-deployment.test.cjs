// Source wiring regression; the factory's atomic EVM behavior is exercised in
// SecurityRemediation.t.sol. No Hardhat config, environment or RPC is loaded here.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
test('every fresh ordinary deployment uses the atomic factory regardless of chain', () => {
  const source = fs.readFileSync(path.join(__dirname, '../deploy/deploy-usdc-vault.ts'), 'utf8');
  const creation = source.slice(source.indexOf('  const existingProxy'));
  assert.match(creation, /if \(existingProxy\)/);
  assert.match(creation, /\} else \{\s*log\(/);
  assert.match(creation, /factoryInstance\.deployAndInitialize\(/);
  assert.doesNotMatch(creation, /else if \(chainId|sendTransaction\(|getCreateAddress\(|startNonce/);
});
