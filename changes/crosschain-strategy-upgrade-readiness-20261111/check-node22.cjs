'use strict';
// Run inside the existing pinned Node 22 ops image with the candidate source
// mounted read-only and Docker --network none. No host credentials are mounted.
const fs = require('node:fs');
const cp = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
assert.match(process.version, /^v22\./);
assert.equal(process.cwd(), '/app/ops');
const runtimeLock = fs.readFileSync('/app/package-lock.json');
assert.ok(runtimeLock.equals(fs.readFileSync('/app/ops/package-lock.json')), 'runtime lock differs from candidate');
const tests = fs.readdirSync('test').filter(name => name.endsWith('.test.ts')).sort().map(name => 'test/' + name);
const result = cp.spawnSync(process.execPath, ['--require', '/app/node_modules/ts-node/register/transpile-only',
  '--test', '--test-reporter=tap', '--test-concurrency=1', ...tests],
  { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const log = (result.stdout || '') + (result.stderr || '');
function sourceFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? sourceFiles(file) : file.endsWith('.ts') ? [file] : [];
  });
}
const typecheck = cp.spawnSync(process.execPath, ['/app/node_modules/typescript/bin/tsc', '--noEmit',
  '--target', 'ES2022', '--module', 'commonjs', '--esModuleInterop', '--resolveJsonModule', '--skipLibCheck',
  ...['src', 'test', 'rehearsal'].flatMap(sourceFiles),
  ...['../deploy/crosschain/registry.ts', '../deploy/crosschain/check.ts'].filter(file => fs.existsSync(file))],
  { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
const config = cp.spawnSync(process.execPath, ['--require', '/app/node_modules/ts-node/register/transpile-only', 'src/check-config.ts'],
  { encoding: 'utf8', maxBuffer: 1024 * 1024, env: { ...process.env,
    RPC_BASE: 'http://127.0.0.1:1', RPC_ARBITRUM: 'http://127.0.0.1:1' } });
const report = { targetCommit: '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7',
  syntheticMergeTree: '7d7a79d568a44fcee33eef7eaad4fd74f4d97870', node: process.version,
  platform: process.platform, architecture: process.arch, sourceMountedReadOnly: true, network: 'none',
  runtimeDependencyLockMatchesCandidate: true,
  dependencyLockSha256: crypto.createHash('sha256').update(runtimeLock).digest('hex'),
  productionWrites: false, testStatus: result.status,
  tests: log.split('\n').filter(line => /^# (tests|pass|fail|cancelled|skipped|todo|duration)/.test(line) || /^not ok/.test(line)),
  skips: log.split('\n').filter(line => /^\s*ok .*# SKIP(?:\s|$)/i.test(line)),
  typecheckStatus: typecheck.status, typecheckOutput: ((typecheck.stdout || '') + (typecheck.stderr || '')).trim(),
  offlineConfigStatus: config.status, offlineConfigOutput: ((config.stdout || '') + (config.stderr || '')).trim(),
  toolchain: Object.fromEntries(['ethers', 'typescript', '@types/node'].map(name =>
    [name, require('/app/node_modules/' + name + '/package.json').version])) };
console.log(JSON.stringify(report, null, 2));
if (result.status !== 0) console.error(log.slice(-4500));
process.exitCode = result.status || typecheck.status || config.status || 0;
