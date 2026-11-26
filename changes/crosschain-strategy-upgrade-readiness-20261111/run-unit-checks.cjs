'use strict';
// Reproducible native local EVM checks without production configuration or RPC.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const dependencyRoot = process.env.ORC_DEPENDENCY_ROOT || root;
const compiler = process.env.SOLC_BINARY || 'solc';
const project = path.join(root, 'out/strategy-upgrade-readiness-20261111/target-main');
const build = path.join(root, 'out/strategy-upgrade-readiness-20261111/unit');
fs.mkdirSync(build, { recursive: true });
const toml = value => JSON.stringify(value);
const config = `[profile.default]
src = ${toml(path.join(project, 'contracts'))}
test = ${toml(path.join(project, 'test'))}
out = ${toml(path.join(build, 'out'))}
cache_path = ${toml(path.join(build, 'cache'))}
libs = [${toml(path.join(dependencyRoot, 'node_modules'))}, ${toml(path.join(dependencyRoot, 'lib'))}]
allow_paths = [${toml(path.dirname(root))}]
auto_detect_remappings = false
remappings = [${toml('@openzeppelin/=' + path.join(dependencyRoot, 'node_modules/@openzeppelin/'))}, ${toml('forge-std/=' + path.join(dependencyRoot, 'lib/forge-std/src/'))}, ${toml('morpho-blue/=' + path.join(dependencyRoot, 'lib/morpho-blue/src/'))}]
optimizer = true
optimizer_runs = 200
evm_version = 'paris'
solc = ${toml(compiler)}
offline = true
[profile.default.fuzz]
runs = 128
[profile.default.invariant]
runs = 64
depth = 128
`;
fs.writeFileSync(path.join(build, 'foundry.toml'), config);
const args = ['test', '--root', build, '--no-match-path', '**/forking/**', '-vv'];
const result = cp.spawnSync(process.env.FORGE_BINARY || 'forge', args, {
  cwd: build, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, FOUNDRY_DISABLE_NIGHTLY_WARNING: '1' },
});
const log = (result.stdout || '') + (result.stderr || '');
fs.writeFileSync(path.join(build, 'unit-checks.log'), log);
const summary = log.split('\n').filter(line => /Ran \d|test result|Suite result|\[FAIL|Error|Compiler run/i.test(line));
const report = { targetCommit: '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7',
  status: result.status, compiler, scope: 'all non-fork repository EVM tests; no RPC/env/key loading',
  summary, productionWrites: false };
fs.writeFileSync(path.join(__dirname, 'unit-verification.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exitCode = result.status ?? 1;
