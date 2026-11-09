// Mounted into the built image by CI; no RPC access or signing keys are needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const requireImage = createRequire('/app/package.json');
requireImage('ts-node/register/transpile-only');
const { loadChains, loadRuntimeManifests, assertTrackedChainsConfigured } = require('/app/ops/src/config.ts');

assert.equal(process.versions.node.split('.')[0], '22');
assert.notEqual(process.getuid(), 0, 'services must run as the existing non-root user');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
assert.equal(db.prepare('select 1 as value').get().value, 1);
db.close();

const deployed = loadRuntimeManifests().map(({ key }) => key);
assert.ok(deployed.includes('base') && deployed.includes('arbitrum'));
for (const network of deployed) process.env[`RPC_${network.toUpperCase()}`] = 'http://127.0.0.1:1';
const chains = loadChains();
assertTrackedChainsConfigured(chains, [8453n, 42161n]);
assert.throws(() => assertTrackedChainsConfigured(chains, [...chains.map((chain) => chain.chainId), 999999n]), /not configured here: 999999/);
for (const chain of chains) chain.provider.destroy();
if (!deployed.includes('mainnet')) {
  process.env.CROSSCHAIN_NETWORKS = 'base,arbitrum,mainnet';
  assert.throws(() => loadChains(), /missing manifest .*mainnet/);
}
process.env.CROSSCHAIN_NETWORKS = 'base,unknown';
assert.throws(() => loadChains(), /unknown network/);
delete process.env.CROSSCHAIN_NETWORKS;

for (const file of ['/app/.env', '/app/.git', '/app/.cto-skill', '/app/.orchestrator-skill', '/app/.product-squad-skill', '/app/.qa-skill', '/app/.security-engineer-skill', '/app/ops/.env.server', '/app/ops/.env.keys', '/app/ops/scripts']) {
  assert.equal(fs.existsSync(file), false, `unexpected image content: ${file}`);
}
for (const file of fs.readdirSync('/app/deployments', { recursive: true })) {
  if (fs.statSync(`/app/deployments/${file}`).isFile()) {
    assert.match(file, /^[^/]+\/crosschain\.json$/, `unrelated deployment artifact in image: ${file}`);
  }
}
console.log(`IMAGE SMOKE PASSED: Node ${process.versions.node}, non-root, SQLite, ${deployed.join('/')}, fail-closed selection, manifest-only image`);
