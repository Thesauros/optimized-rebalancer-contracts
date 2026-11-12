'use strict';
// Exercise the existing companion commit from immutable Git objects, not its worktree.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers'))
  ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const commit = '31380600e6e33655600f071ac8cb8cd568291392';
const checkout = path.join(root, 'out/strategy-upgrade-readiness-20261111/companion-tests');
const sources = cp.execFileSync('git', ['ls-tree', '-r', '--name-only', commit, '--', 'ops/src'],
  { cwd: root, encoding: 'utf8' }).trim().split('\n');
sources.push('ops/test/strategy-value.test.ts', 'deploy/crosschain/registry.ts');
for (const source of sources) {
  const file = path.join(checkout, source);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, cp.execFileSync('git', ['show', commit + ':' + source], { cwd: root }));
}
const args = ['--require', path.join(deps, 'ops/node_modules/ts-node/register/transpile-only'),
  '--test', '--test-reporter=tap', path.join(checkout, 'ops/test/strategy-value.test.ts')];
const result = cp.spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
  env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
    NODE_PATH: [path.join(deps, 'ops/node_modules'), path.join(deps, 'node_modules')].join(path.delimiter),
    TS_NODE_PROJECT: path.join(root, 'ops/tsconfig.json') } });
const log = (result.stdout || '') + (result.stderr || '');
fs.writeFileSync(path.join(checkout, 'strategy-value-tests.log'), log);
const summary = log.split('\n').filter(line => /^# (tests|pass|fail|cancelled|skipped|todo|duration)/.test(line) || /^not ok/.test(line));
const report = { companionCommit: commit, status: result.status, summary,
  scope: 'source-identical existing companion tests, including NAV positions and RPC/revert classification',
  originalWorktreeModified: false, productionWrites: false };
fs.writeFileSync(path.join(__dirname, 'companion-verification.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
if (result.status !== 0) console.error(log.slice(-5000));
process.exitCode = result.status ?? 1;
