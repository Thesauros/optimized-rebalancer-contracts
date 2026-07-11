const path = require('path');
const { spawnSync } = require('child_process');

require('./prepare-tron-sources');

const root = path.resolve(__dirname, '..');
const tronbox = path.join(root, 'node_modules', 'tronbox', 'build', 'tronbox.js');
const compilerEnv = { ...process.env };

// The compiler never needs signing material. Keep private keys out of the
// TronBox process and its transitive dependency tree.
for (const name of [
  'TRON_DEPLOYER_PRIVATE_KEY',
  'DEPLOYER_PRIVATE_KEY',
  'PRIVATE_KEY',
  'MNEMONIC',
]) {
  delete compilerEnv[name];
}

const result = spawnSync(process.execPath, [tronbox, 'compile', '--all'], {
  cwd: root,
  env: compilerEnv,
  stdio: 'inherit',
});

if (result.error) throw result.error;
process.exitCode = result.status === null ? 1 : result.status;

