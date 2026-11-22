'use strict';
// Deploy reviewed Paris bytecodes into an in-memory fork with current venue EVM rules.
// No signer, private key, public broadcast or unpinned fork is used.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '..');
const scrub = value => String(value).replace(/https?:\/\/[^\s"'<>]+/g, '[RPC URL]');
try {
  const pin = process.env.ARBITRUM_FORK_BLOCK;
  if (!process.env.ARBITRUM_RPC_URL || !/^\d+$/.test(pin || '') || BigInt(pin) <= 0n) {
    throw new Error('ARBITRUM_RPC_URL and a positive explicit ARBITRUM_FORK_BLOCK are required');
  }
  const env = {};
  // Forward only execution settings and the read RPC; signing credentials are unnecessary.
  for (const key of ['PATH', 'HOME', 'LANG', 'TMPDIR', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY']) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  Object.assign(env, { ARBITRUM_RPC_URL: process.env.ARBITRUM_RPC_URL,
    ARBITRUM_FORK_BLOCK: pin, FOUNDRY_EVM_VERSION: 'prague' });
  for (const [key, file] of [
    ['ARBITRUM_STRATEGY_CREATION_CODE', 'Rebalancer.sol/Rebalancer'],
    ['ARBITRUM_FLUID_CREATION_CODE', 'providers/FluidProvider.sol/FluidProvider'],
    ['ARBITRUM_V2_CREATION_CODE', 'providers/MorphoV2Provider.sol/MorphoV2Provider'],
  ]) {
    const artifact = JSON.parse(fs.readFileSync(path.join(root, 'artifacts/contracts', file + '.json'), 'utf8'));
    if (!/^0x[0-9a-f]+$/i.test(artifact.bytecode)) throw new Error('Compile complete deployment artifacts first');
    env[key] = artifact.bytecode;
  }
  const args = ['test', '--match-path', 'test/forking/ArbitrumStrategyUpgrade.t.sol',
    '--out', path.join(root, 'out/arbitrum-upgrade-rehearsal'),
    '--cache-path', path.join(root, 'cache_forge/arbitrum-upgrade-rehearsal'), '-vv'];
  if (process.env.SOLC_BINARY) args.push('--use', process.env.SOLC_BINARY);
  const result = cp.spawnSync(process.env.FORGE_BINARY || 'forge', args,
    { cwd: root, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.stdout) process.stdout.write(scrub(result.stdout));
  if (result.stderr) process.stderr.write(scrub(result.stderr));
  if (result.error) throw result.error;
  process.exitCode = result.status === 0 ? 0 : 1;
} catch (error) {
  console.error(scrub(error.message));
  process.exitCode = 1;
}
