'use strict';
// Offline compiler/storage verification. No Hardhat config, dotenv, keys or RPC.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const dependencyRoot = process.env.ORC_DEPENDENCY_ROOT || root;
const E = require(path.join(dependencyRoot, 'ops/node_modules/ethers'));
const compiler = process.env.SOLC_BINARY || 'solc';
const output = path.join(root, 'out/strategy-upgrade-readiness-20261111');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'deployments/base/crosschain.json')));
const expectedRuntimeHash = manifest.codehashes.StrategyImplementation;
const targetCommit = '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7';
const hash = value => E.keccak256(E.toUtf8Bytes(value));
const save = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
fs.mkdirSync(output, { recursive: true });
const legacyCommit = '9a53cc77c38cf76e9323f9225fe883e3c6985a00';
const solcVersion = cp.execFileSync(compiler, ['--version'], { encoding: 'utf8' }).trim();
assert.match(solcVersion, /0\.8\.33\+commit\.64118f21/);
function compile(sources, selection) {
  const input = { language: 'Solidity', sources, settings: {
    optimizer: { enabled: true, runs: 200 }, evmVersion: 'paris',
    metadata: { useLiteralContent: true }, outputSelection: selection,
  } };
  const result = cp.spawnSync(compiler, ['--standard-json'], {
    input: JSON.stringify(input), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  const errors = (parsed.errors || []).filter(error => error.severity === 'error');
  assert.equal(errors.length, 0, JSON.stringify(errors));
  return parsed;
}
function sourceGraph(gitCommit) {
  const sources = {};
  const queue = ['contracts/Rebalancer.sol'];
  for (let i = 0; i < queue.length; i++) {
    const unit = queue[i];
    const file = unit.startsWith('@') ? path.join(dependencyRoot, 'node_modules', unit) : path.join(root, unit);
    sources[unit] = { content: gitCommit && !unit.startsWith('@')
      ? cp.execFileSync('git', ['show', gitCommit + ':' + unit], { cwd: root, encoding: 'utf8' })
      : fs.readFileSync(file, 'utf8') };
    for (const match of sources[unit].content.matchAll(/import\s+(?:[^;]*?\s+from\s+)?["']([^"']+)["']\s*;/g)) {
      const name = match[1].startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(unit), match[1])) : match[1];
      if (!queue.includes(name)) queue.push(name);
    }
  }
  return sources;
}
const targetSources = sourceGraph(targetCommit);
const legacy = { input: { language: 'Solidity', sources: sourceGraph(legacyCommit) } };
const selectRuntime = { 'contracts/Rebalancer.sol': { Rebalancer: ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'metadata'] } };
const oldRuntime = compile(legacy.input.sources, selectRuntime).contracts['contracts/Rebalancer.sol'].Rebalancer;
assert.equal(E.keccak256('0x' + oldRuntime.evm.deployedBytecode.object), expectedRuntimeHash, 'native rebuild differs from live runtime');
const newRuntime = compile(targetSources, selectRuntime).contracts['contracts/Rebalancer.sol'].Rebalancer;
assert.equal(Object.keys(newRuntime.evm.bytecode.linkReferences).length, 0, 'unresolved target libraries');
assert.ok(newRuntime.evm.deployedBytecode.object.length / 2 <= 24576, 'runtime exceeds EIP-170');
const probe = { content: 'pragma solidity 0.8.33; import {Rebalancer} from "contracts/Rebalancer.sol"; contract UpgradeStorageProbe { Rebalancer.RebalancerStorage internal state; }' };
function layout(sources) {
  const result = compile({ ...sources, 'UpgradeStorageProbe.sol': probe }, {
    'UpgradeStorageProbe.sol': { UpgradeStorageProbe: ['storageLayout'] },
  }).contracts['UpgradeStorageProbe.sol'].UpgradeStorageProbe.storageLayout;
  const type = result.types[result.storage[0].type];
  return type.members.map(member => ({ name: member.label, slot: member.slot,
    offset: member.offset, type: result.types[member.type].label }));
}
const before = layout(legacy.input.sources), after = layout(targetSources);
assert.deepEqual(after.slice(0, before.length), before, 'actual deployed storage prefix incompatible');
const namespace = source => source.match(/bytes32 private constant RebalancerStorageLocation\s*=\s*(0x[0-9a-f]+);/)[1];
assert.equal(namespace(legacy.input.sources['contracts/Rebalancer.sol'].content), namespace(targetSources['contracts/Rebalancer.sol'].content));
const inheritedSources = Object.keys(targetSources).filter(unit => unit.startsWith('@openzeppelin/') ||
  ['contracts/access/AccessManager.sol', 'contracts/utils/PausableActions.sol', 'contracts/interfaces/IAccessManager.sol', 'contracts/interfaces/IPausableActions.sol'].includes(unit));
const preserved = inheritedSources.filter(unit => legacy.input.sources[unit]);
for (const unit of preserved) assert.equal(hash(targetSources[unit].content), hash(legacy.input.sources[unit].content), 'inherited source changed: ' + unit);
const report = { targetCommit, compiler: solcVersion,
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'paris', metadata: { useLiteralContent: true } },
  exactDeployedRuntimeRebuilt: true, legacyGitCommit: legacyCommit, legacyRuntimeHash: expectedRuntimeHash,
  targetRuntimeHash: E.keccak256('0x' + newRuntime.evm.deployedBytecode.object),
  targetCreationHash: E.keccak256('0x' + newRuntime.evm.bytecode.object), targetRuntimeBytes: newRuntime.evm.deployedBytecode.object.length / 2,
  namespace: namespace(targetSources['contracts/Rebalancer.sol'].content), legacyFields: before,
  appendedFields: after.slice(before.length), inheritedSourcesPreserved: preserved,
  sourceHashes: Object.fromEntries(Object.entries(targetSources).map(([name, source]) => [name, hash(source.content)])),
  storageCompatible: true, productionWrites: false };
save(path.join(output, 'target-Rebalancer.json'), { abi: newRuntime.abi,
  bytecode: '0x' + newRuntime.evm.bytecode.object, deployedBytecode: '0x' + newRuntime.evm.deployedBytecode.object });
save(path.join(output, 'legacy-compiler-input.json'), legacy.input);
save(path.join(output, 'target-sources.json'), targetSources);
save(path.join(__dirname, 'build-verification.json'), report);
console.log(JSON.stringify({ exactDeployedRuntimeRebuilt: true, legacyFieldsPreserved: before.length,
  appendedFields: report.appendedFields, targetRuntimeBytes: report.targetRuntimeBytes,
  targetRuntimeHash: report.targetRuntimeHash, inheritedSourcesPreserved: preserved.length }, null, 2));
