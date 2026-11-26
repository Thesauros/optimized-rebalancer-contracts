'use strict';
// Read-only comparison with strategy deployment blocks; failed archive reads are explicit limitations.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers')) ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const E = require(path.join(deps, 'ops/node_modules/ethers'));
const strategyAbi = new E.Interface(['function getProviders() view returns(address[])', 'function getEntryProvider() view returns(address)']);
const providerAbi = new E.Interface(['function getSource(address,address,address) view returns(address)']);
const rpcReadMethods = ['eth_chainId', 'eth_getTransactionReceipt', 'eth_call', 'eth_getBlockByNumber'];
class ReadOnly extends E.JsonRpcProvider {
  async send(method, params) {
    if (!rpcReadMethods.includes(method)) throw new Error('write prohibited');
    return super.send(method, params);
  }
}
async function call(p, tag, to, abi, name, args = []) {
  return abi.decodeFunctionResult(name, await p.send('eth_call', [{ to, data: abi.encodeFunctionData(name, args) }, tag]))[0];
}
async function check(network, url) {
  const request = new E.FetchRequest(url); request.timeout = 20000;
  const p = new ReadOnly(request, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  const m = JSON.parse(fs.readFileSync(path.join(root, 'deployments', network, 'crosschain.json')));
  const fork = JSON.parse(fs.readFileSync(path.join(__dirname, network + '-fork-verification.json')));
  const result = { network, productionWrites: false, historicalHwmAttested: false,
    note: 'Source comparison does not reconstruct an unrecorded all-time PPS maximum.' };
  try {
    const receipt = await p.send('eth_getTransactionReceipt', [m.txs.Strategy]);
    if (!receipt || BigInt(receipt.status) !== 1n) throw new Error('deployment receipt unavailable');
    result.deploymentBlock = Number(BigInt(receipt.blockNumber));
    const providers = Array.from(await call(p, receipt.blockNumber, m.contracts.Strategy, strategyAbi, 'getProviders'));
    result.providersAtDeployment = providers;
    result.providerListMatchesCurrent = JSON.stringify(providers) === JSON.stringify(fork.before.providers);
    result.readLimitations = [];
    try {
      result.entryAtDeployment = await call(p, receipt.blockNumber, m.contracts.Strategy, strategyAbi, 'getEntryProvider');
      result.entryMatchesCurrent = result.entryAtDeployment === fork.before.entry;
    } catch (e) {
      result.readLimitations.push({ field: 'entry', code: e.code || 'read error',
        nodeMessage: String(e?.info?.error?.message || e.shortMessage || e.message).slice(0, 200) });
    }
    result.sources = {};
    for (const provider of providers) {
      try {
        const source = await call(p, receipt.blockNumber, provider, providerAbi, 'getSource', [fork.before.asset, m.contracts.Strategy, E.ZeroAddress]);
        result.sources[provider] = { atDeployment: source, current: fork.before.sources[provider], matches: source === fork.before.sources[provider] };
      } catch (e) {
        result.readLimitations.push({ field: provider, code: e.code || 'read error',
          nodeMessage: String(e?.info?.error?.message || e.shortMessage || e.message).slice(0, 200) });
      }
    }
    result.deploymentSourcesAttested = result.providerListMatchesCurrent && result.entryMatchesCurrent &&
      result.readLimitations.length === 0 && Object.values(result.sources).every(x => x.matches);
  } catch (e) {
    result.deploymentSourcesAttested = false;
    result.historicalReadLimitation = { code: e.code || 'read error',
      nodeMessage: String(e?.info?.error?.message || e.shortMessage || e.message || '').replace(/https?:\/\/[^\s"']+/g, '[RPC]').slice(0, 220) };
  } finally { p.destroy(); }
  return result;
}
function configuredArbitrumReadUrl() {
  // Extract only read-RPC assignments. Never load dotenv, signer variables or
  // private keys into process.env; never print/persist the authenticated URL.
  const file = process.env.ORC_READ_RPC_ENV_FILE || path.join(deps, '.env');
  const values = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?(RPC_ARBITRUM|ARBITRUM_RPC_URL)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    values[match[1]] = value;
  }
  const url = values.RPC_ARBITRUM || values.ARBITRUM_RPC_URL;
  if (!url || new URL(url).protocol !== 'https:') throw new Error('configured HTTPS read RPC unavailable');
  return url;
}
async function checkMissingArbitrum(configured = false) {
  const prior = JSON.parse(fs.readFileSync(path.join(__dirname, 'historical-source-verification.json')))
    .find(item => item.network === 'arbitrum');
  const fork = JSON.parse(fs.readFileSync(path.join(__dirname, 'arbitrum-fork-verification.json')));
  const m = JSON.parse(fs.readFileSync(path.join(root, 'deployments/arbitrum/crosschain.json')));
  const request = new E.FetchRequest(configured ? configuredArbitrumReadUrl() : 'https://arbitrum-one-rpc.publicnode.com');
  request.timeout = 20000;
  const p = new ReadOnly(request, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  const result = { network: 'arbitrum', endpoint: configured ? 'configured Arbitrum read RPC; URL withheld'
    : 'https://arbitrum-one-rpc.publicnode.com',
    deploymentBlock: prior.deploymentBlock, productionWrites: false, sources: {} };
  try {
    if (BigInt(await p.send('eth_chainId', [])) !== 42161n) throw new Error('wrong chain');
    for (const provider of fork.before.providers.filter(provider => !prior.sources[provider])) {
      try {
        const source = await call(p, '0x' + prior.deploymentBlock.toString(16), provider, providerAbi,
          'getSource', [fork.before.asset, m.contracts.Strategy, E.ZeroAddress]);
        result.sources[provider] = { atDeployment: source, current: fork.before.sources[provider],
          matches: source === fork.before.sources[provider] };
      } catch (e) {
        result.sources[provider] = { readLimitation: { code: e.code || 'read error',
          ...(configured ? { nodeMessage: 'Configured archive read failed; authenticated endpoint details withheld.' }
            : { nodeMessage: String(e?.info?.error?.message || e.shortMessage || e.message).slice(0, 220) }) } };
      }
    }
  } finally { p.destroy(); }
  result.allMissingSourcesAttested = Object.values(result.sources).length > 0 &&
    Object.values(result.sources).every(item => item.matches === true);
  fs.writeFileSync(path.join(__dirname, configured ? 'arbitrum-configured-historical-verification.json'
    : 'arbitrum-secondary-historical-verification.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
}
const operation = process.argv[2] === 'arbitrum-configured' ? checkMissingArbitrum(true)
  : process.argv[2] === 'arbitrum-secondary' ? checkMissingArbitrum() :
  Promise.all([check('base', 'https://mainnet.base.org'), check('arbitrum', 'https://arb1.arbitrum.io/rpc')]).then(result => {
  fs.writeFileSync(path.join(__dirname, 'historical-source-verification.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
});
operation.catch(e => { console.error('History check failed: ' + (e.code || 'error')); process.exitCode = 1; });
