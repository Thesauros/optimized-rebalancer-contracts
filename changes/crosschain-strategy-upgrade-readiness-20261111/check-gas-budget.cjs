'use strict';
// Read-only deployment estimates; no transaction signing or submission.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers')) ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const E = require(path.join(deps, 'ops/node_modules/ethers'));
const artifact = JSON.parse(fs.readFileSync(path.join(root, 'out/strategy-upgrade-readiness-20261111/target-Rebalancer.json')));
const build = JSON.parse(fs.readFileSync(path.join(__dirname, 'build-verification.json')));
class ReadOnly extends E.JsonRpcProvider {
  async send(method, params) {
    if (!['eth_chainId', 'eth_getBalance', 'eth_gasPrice', 'eth_estimateGas', 'eth_getBlockByNumber', 'eth_getCode'].includes(method)) {
      throw new Error('public writes prohibited');
    }
    return super.send(method, params);
  }
}
async function check(network, url) {
  const req = new E.FetchRequest(url); req.timeout = 30000;
  const p = new ReadOnly(req, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  const m = JSON.parse(fs.readFileSync(path.join(root, 'deployments', network, 'crosschain.json')));
  const fork = JSON.parse(fs.readFileSync(path.join(__dirname, network + '-fork-verification.json')));
  const result = { network, owner: m.deployer, targetCommit: build.targetCommit,
    targetRuntimeHash: build.targetRuntimeHash, productionWrites: false,
    limitation: 'Point-in-time gas estimate times quoted gas price; additional rollup/data fees and future prices are not attested.' };
  try {
    if (fork.targetCommit !== build.targetCommit) throw new Error('migration gas evidence belongs to an earlier target; rerun forks first');
    const [chain, head, balance, price] = await Promise.all([
      p.send('eth_chainId', []), p.send('eth_getBlockByNumber', ['latest', false]),
      p.send('eth_getBalance', [m.deployer, 'latest']), p.send('eth_gasPrice', []),
    ]);
    if (BigInt(chain) !== BigInt(m.chainId)) throw new Error('wrong chain');
    Object.assign(result, { observedBlock: Number(BigInt(head.number)),
      observedAtUtc: new Date(Number(BigInt(head.timestamp)) * 1000).toISOString(),
      signerBalanceWei: BigInt(balance).toString(), signerBalanceEth: E.formatEther(BigInt(balance)),
      gasPriceWei: BigInt(price).toString() });
    const knownFile = path.join(root, 'deployments', network, 'USDCRebalancerImplementation.json');
    if (fs.existsSync(knownFile)) {
      const known = JSON.parse(fs.readFileSync(knownFile));
      if (E.isAddress(known.address)) {
        const code = await p.send('eth_getCode', [known.address, 'latest']);
        result.knownStandaloneImplementation = { address: known.address,
          runtimeHash: E.keccak256(code),
          matchesTarget: code.toLowerCase() === artifact.deployedBytecode.toLowerCase() };
      }
    }
    const estimate = BigInt(await p.send('eth_estimateGas', [{ from: m.deployer, data: artifact.bytecode, value: '0x0' }]));
    const upgrade = BigInt(fork.localMigrationGasUsed);
    const quoted = (estimate + upgrade) * BigInt(price);
    Object.assign(result, { implementationCreationGas: estimate.toString(), locallyMeasuredUpgradeGas: upgrade.toString(),
      quotedExecutionCostWei: quoted.toString(), quotedExecutionCostEth: E.formatEther(quoted),
      balanceCoversQuotedExecutionOnly: BigInt(balance) >= quoted });
  } catch (e) {
    result.estimateLimitation = { code: e.code || 'read error',
      nodeMessage: String(e?.info?.error?.message || e.shortMessage || e.message).replace(/https?:\/\/[^\s"']+/g, '[RPC]').slice(0, 220) };
  } finally { p.destroy(); }
  return result;
}
Promise.all([check('base', 'https://mainnet.base.org'), check('arbitrum', 'https://arb1.arbitrum.io/rpc')]).then(result => {
  fs.writeFileSync(path.join(__dirname, 'gas-budget-verification.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
}).catch(e => { console.error('Gas budget read failed: ' + (e.code || 'error')); process.exitCode = 1; });
