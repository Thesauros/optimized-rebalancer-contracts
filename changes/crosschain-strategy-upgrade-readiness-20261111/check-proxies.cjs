'use strict';
// Attest existing implementations/admins. Public RPC is restricted to reads.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers'))
  ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
const E = require(path.join(deps, 'ops/node_modules/ethers'));
const implementationSlot = E.toBeHex(BigInt(E.id('eip1967.proxy.implementation')) - 1n, 32);
const adminSlot = E.toBeHex(BigInt(E.id('eip1967.proxy.admin')) - 1n, 32);
const abi = new E.Interface(['function owner() view returns(address)']);
class ReadOnly extends E.JsonRpcProvider {
  async send(method, params) {
    assert.ok(['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call'].includes(method),
      'public write prohibited');
    return super.send(method, params);
  }
}
async function check(network, url, names) {
  const request = new E.FetchRequest(url); request.timeout = 30000;
  const rpc = new ReadOnly(request, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'deployments', network, 'crosschain.json')));
  try {
    assert.equal(BigInt(await rpc.send('eth_chainId', [])), BigInt(manifest.chainId));
    const head = await rpc.send('eth_getBlockByNumber', ['latest', false]);
    const proxies = [];
    for (const name of names) {
      const address = manifest.contracts[name];
      const [implementationWord, adminWord] = await Promise.all([
        rpc.send('eth_getStorageAt', [address, implementationSlot, head.number]),
        rpc.send('eth_getStorageAt', [address, adminSlot, head.number]),
      ]);
      const implementation = E.getAddress('0x' + implementationWord.slice(-40));
      const proxyAdmin = E.getAddress('0x' + adminWord.slice(-40));
      const [code, ownerResult] = await Promise.all([
        rpc.send('eth_getCode', [implementation, head.number]),
        rpc.send('eth_call', [{ to: proxyAdmin, data: abi.encodeFunctionData('owner') }, head.number]),
      ]);
      const owner = abi.decodeFunctionResult('owner', ownerResult)[0];
      assert.equal(implementation.toLowerCase(), manifest.contracts[name + 'Implementation'].toLowerCase());
      assert.equal(E.keccak256(code), manifest.codehashes[name + 'Implementation']);
      assert.equal(owner, manifest.deployer);
      proxies.push({ name, proxy: address, implementation, proxyAdmin, owner,
        implementationRuntimeHash: E.keccak256(code), matchesManifest: true });
    }
    assert.equal((await rpc.send('eth_getBlockByNumber', [head.number, false])).hash, head.hash);
    return { network, blockNumber: Number(BigInt(head.number)), blockHash: head.hash,
      observedAtUtc: new Date(Number(BigInt(head.timestamp)) * 1000).toISOString(), proxies, productionWrites: false };
  } finally { rpc.destroy(); }
}
Promise.all([
  check('base', 'https://mainnet.base.org', ['Strategy', 'EpochVault', 'TickAccountant', 'ChainAgent']),
  check('arbitrum', 'https://arb1.arbitrum.io/rpc', ['Strategy', 'ChainAgent']),
]).then(result => {
  fs.writeFileSync(path.join(__dirname, 'proxy-verification.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
}).catch(e => {
  console.error('Proxy attestation failed: ' + (e.code || 'audit error') + ': ' +
    String(e?.info?.error?.message || e.shortMessage || e.message).replace(/https?:\/\/[^\s"']+/g, '[RPC]').slice(0, 400));
  process.exitCode = 1;
});
