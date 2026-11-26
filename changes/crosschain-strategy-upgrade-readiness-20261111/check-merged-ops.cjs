'use strict';
// Validate the companion fix together with the reproducible-ops work, without
// moving any branch/index or changing another agent's checkout.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers')) ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const operationalCommit = '15f1dab998eb12a1ed273c045ae7c52c5b13af3c';
const companionCommit = '31380600e6e33655600f071ac8cb8cd568291392';
const targetCommit = '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7';
const upstreamMerge = cp.spawnSync('git', ['merge-tree', '--write-tree', '--name-only', operationalCommit, targetCommit],
  { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
assert.equal(upstreamMerge.status, 0, 'upstream merge conflicts: ' + upstreamMerge.stdout);
const upstreamTree = upstreamMerge.stdout.trim().split('\n')[0];
const syntheticCommit = cp.execFileSync('git', ['commit-tree', upstreamTree, '-p', operationalCommit, '-p', targetCommit,
  '-m', '[crosschain-strategy-upgrade-readiness-20261111] Unreferenced verification candidate'], { cwd: root, encoding: 'utf8' }).trim();
const merge = cp.spawnSync('git', ['merge-tree', '--write-tree', '--name-only', syntheticCommit, companionCommit],
  { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
assert.equal(merge.status, 0, 'companion merge conflicts: ' + merge.stdout);
const tree = merge.stdout.trim().split('\n')[0];
assert.match(tree, /^[0-9a-f]{40}$/);
const candidate = path.join(root, 'out/strategy-upgrade-readiness-20261111/merged-ops');
fs.mkdirSync(candidate, { recursive: true });
const archive = cp.execFileSync('git', ['archive', '--format=tar', tree], { cwd: root, maxBuffer: 128 * 1024 * 1024 });
cp.execFileSync('tar', ['-x', '-C', candidate], { input: archive });
for (const [target, source] of [[path.join(candidate, 'node_modules'), path.join(deps, 'node_modules')],
  [path.join(candidate, 'ops/node_modules'), path.join(deps, 'ops/node_modules')]]) {
  if (!fs.existsSync(target)) fs.symlinkSync(source, target, 'dir');
}
const env = { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
  NODE_PATH: [path.join(deps, 'ops/node_modules'), path.join(deps, 'node_modules')].join(path.delimiter),
  TS_NODE_PROJECT: path.join(candidate, 'ops/tsconfig.json') };
const tests = fs.readdirSync(path.join(candidate, 'ops/test')).filter(name => name.endsWith('.test.ts')).sort()
  .map(name => path.join(candidate, 'ops/test', name));
const result = cp.spawnSync(process.execPath, ['--require', path.join(deps, 'ops/node_modules/ts-node/register/transpile-only'),
  '--test', '--test-reporter=tap', '--test-concurrency=1', ...tests],
  { cwd: path.join(candidate, 'ops'), encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env });
const log = (result.stdout || '') + (result.stderr || '');
fs.writeFileSync(path.join(candidate, 'merged-ops-tests.log'), log);
const typecheck = cp.spawnSync(process.execPath, [path.join(deps, 'ops/node_modules/typescript/bin/tsc'), '--noEmit',
  '--target', 'ES2022', '--module', 'commonjs', '--esModuleInterop', '--resolveJsonModule', '--skipLibCheck',
  ...cp.execFileSync('git', ['ls-tree', '-r', '--name-only', tree, '--', 'ops/src', 'ops/test', 'ops/rehearsal', 'deploy/crosschain'],
    { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(name => name.endsWith('.ts') &&
      (name.startsWith('ops/') || ['deploy/crosschain/registry.ts', 'deploy/crosschain/check.ts'].includes(name)))
      .map(name => path.join(candidate, name))],
  { cwd: candidate, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, env });
const typeLog = (typecheck.stdout || '') + (typecheck.stderr || '');
fs.writeFileSync(path.join(candidate, 'merged-ops-typecheck.log'), typeLog);
const report = { operationalCommit, companionCommit, targetCommit, syntheticMergeTree: tree, mergeConflicts: false,
  productBranchesModified: false, productionWrites: false, testStatus: result.status,
  tests: log.split('\n').filter(line => /^# (tests|pass|fail|cancelled|skipped|todo|duration)/.test(line) || /^not ok/.test(line)),
  typecheckStatus: typecheck.status, typecheckOutput: typeLog.trim().slice(0, 4000),
  toolchain: { ethers: require(path.join(deps, 'ops/node_modules/ethers/package.json')).version,
    typescript: require(path.join(deps, 'ops/node_modules/typescript/package.json')).version,
    nodeTypes: require(path.join(deps, 'ops/node_modules/@types/node/package.json')).version } };
fs.writeFileSync(path.join(__dirname, 'merged-ops-verification.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
if (result.status !== 0) console.error(log.slice(-4500));
process.exitCode = result.status || typecheck.status || 0;
