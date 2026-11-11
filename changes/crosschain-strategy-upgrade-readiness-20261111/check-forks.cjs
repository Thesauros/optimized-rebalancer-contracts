'use strict';
// Production RPCs have a closed read allowlist. Every write is loopback Anvil only.
// No dotenv, production key, Wallet, signing or public broadcast code exists here.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const net = require('node:net');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const deps = process.env.ORC_DEPENDENCY_ROOT || (fs.existsSync(path.join(root, 'ops/node_modules/ethers'))
  ? root : path.resolve(root, '../optimized-rebalancer-contracts'));
process.env.NODE_PATH = [path.join(deps, 'ops/node_modules'), path.join(deps, 'node_modules')].join(path.delimiter);
require('node:module').Module._initPaths();
const E = require(path.join(deps, 'ops/node_modules/ethers'));
const out = path.join(root, 'out/strategy-upgrade-readiness-20261111');
const artifact = JSON.parse(fs.readFileSync(path.join(out, 'target-Rebalancer.json')));
const build = JSON.parse(fs.readFileSync(path.join(__dirname, 'build-verification.json')));
const si = new E.Interface([...artifact.abi, 'error Timelock__StillLocked()']);
const adminAbi = new E.Interface(['function owner() view returns(address)', 'function upgradeAndCall(address,address,bytes) payable']);
const timelockAbi = new E.Interface(['function owner() view returns(address)', 'function delay() view returns(uint256)',
  'function queue(address,uint256,string,bytes,uint256) returns(bytes32)',
  'function execute(address,uint256,string,bytes,uint256) payable returns(bytes)']);
const providerAbi = new E.Interface(['function getSource(address,address,address) view returns(address)', 'function getDepositBalance(address,address) view returns(uint256)']);
const tokenAbi = new E.Interface(['function balanceOf(address) view returns(uint256)', 'function allowance(address,address) view returns(uint256)']);
const agentAbi = new E.Interface(['function strategyShares() view returns(uint256)', 'function idle() view returns(uint256)',
  'function deallocate(uint256) returns(uint256)', 'function allocate(uint256) returns(uint256)', 'function returnToVault(uint256)']);
const vaultAbi = new E.Interface(['function accounting() view returns(uint256,uint256,uint256,uint256,uint256,uint256)',
  'function limits() view returns(uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64)',
  'error TickNotUsable()', 'function accountant() view returns(address)',
  'function minimumBuffer() view returns(uint256)', 'function pushToAgent(uint256)', 'function balanceOf(address) view returns(uint256)',
  'function getRequest(uint256) view returns((address,address,uint64,uint8,uint8,uint128))',
  'function instantRedeem(uint256,address,address,uint256) returns(uint256)']);
const tickAbi = new E.Interface(['function frozen() view returns(bool)',
  'function latestAccepted() view returns(uint64,(uint64,uint64,uint64,uint8,uint8,uint128,uint128,uint128,uint128,bytes32))']);
const implSlot = E.toBeHex(BigInt(E.id('eip1967.proxy.implementation')) - 1n, 32);
const adminSlot = E.toBeHex(BigInt(E.id('eip1967.proxy.admin')) - 1n, 32);
const namespace = BigInt(build.namespace);
const COMPANION = '31380600e6e33655600f071ac8cb8cd568291392';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
const save = (name, value) => fs.writeFileSync(path.join(__dirname, name), json(value) + '\n');
const status = (network, stage) => console.log(json({ network, stage }));
let localTransactionSequence = 0;
class ReadOnlyProvider extends E.JsonRpcProvider {
  async send(method, params) {
    assert.ok(['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call',
      'eth_getLogs', 'eth_getTransactionByHash', 'eth_getTransactionReceipt'].includes(method), 'public write prohibited: ' + method);
    for (let attempt = 0; ; attempt++) {
      try { return await super.send(method, params); } catch (e) {
        const retryable = ['TIMEOUT', 'NETWORK_ERROR', 'SERVER_ERROR'].includes(e.code) ||
          /429|502|503|504|rate limit|timed? out/i.test(String(e?.info?.error?.message || e.message));
        if (!retryable || attempt >= 2) throw e;
        await pause(1000 * (attempt + 1));
      }
    }
  }
}
class LocalProvider extends E.JsonRpcProvider {
  constructor(url) {
    const u = new URL(url);
    assert.equal(u.protocol, 'http:'); assert.equal(u.hostname, '127.0.0.1');
    const req = new E.FetchRequest(url); req.timeout = 120000;
    super(req, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
    this.allowed = false;
  }
  async send(method, params) {
    if (!['web3_clientVersion', 'eth_chainId', 'eth_getBlockByNumber'].includes(method)) {
      assert.ok(this.allowed, 'local fork identity not verified');
    }
    return super.send(method, params);
  }
}
async function call(p, tag, to, abi, method, args = [], from) {
  const result = await p.send('eth_call', [{ to, data: abi.encodeFunctionData(method, args), ...(from ? { from } : {}) }, tag]);
  return abi.decodeFunctionResult(method, result);
}
const one = async (...args) => (await call(...args))[0];
function revertData(e) { return e?.data ?? e?.info?.error?.data ?? e?.error?.data; }
function parseError(data) {
  if (typeof data !== 'string' || data.length <= 2) return undefined;
  for (const abi of [si, vaultAbi]) {
    try { const parsed = abi.parseError(data); if (parsed) return parsed; } catch {}
  }
}
async function mustRevert(p, tx, expected) {
  try { await p.call(tx); } catch (e) {
    const data = revertData(e);
    assert.ok(typeof data === 'string' || /revert/i.test(e?.info?.error?.message || ''), 'RPC error cannot prove revert');
    const parsed = parseError(data);
    if (Array.isArray(expected)) assert.ok(expected.includes(parsed?.name), 'unexpected revert: ' + parsed?.name);
    else if (expected) assert.equal(parsed?.name, expected, 'unexpected revert');
    return { reverted: true, error: parsed?.name || 'execution reverted' };
  }
  throw new Error('expected execution revert did not occur');
}
async function payoutHolder(p, m, tag) {
  const candidates = [m.deployer];
  for (let id = 1; id <= 8; id++) {
    const request = await one(p, tag, m.contracts.EpochVault, vaultAbi, 'getRequest', [id]);
    candidates.push(request[0], request[1]);
  }
  for (const candidate of [...new Set(candidates)]) {
    if (candidate === E.ZeroAddress || candidate === m.contracts.EpochVault) continue;
    if (await one(p, tag, m.contracts.EpochVault, vaultAbi, 'balanceOf', [candidate]) >= 500000n) return candidate;
  }
  throw new Error('no actual user holder found for instant payout proof');
}
async function payoutBaseline(p, m, tag, holder) {
  if (!m.contracts.EpochVault) return undefined;
  const vault = m.contracts.EpochVault;
  const block = await p.send('eth_getBlockByNumber', [tag, false]);
  const accountant = await one(p, tag, vault, vaultAbi, 'accountant');
  const [limits, latest, frozen] = await Promise.all([
    call(p, tag, vault, vaultAbi, 'limits'),
    call(p, tag, accountant, tickAbi, 'latestAccepted'),
    one(p, tag, accountant, tickAbi, 'frozen'),
  ]);
  holder ||= await payoutHolder(p, m, tag);
  const age = BigInt(block.timestamp) - latest[1][1];
  let simulation;
  try {
    const result = await call(p, tag, vault, vaultAbi, 'instantRedeem', [500000n, holder, holder, 1n], holder);
    simulation = { passed: true, assets: result[0] };
  } catch (e) {
    const parsed = parseError(revertData(e));
    assert.ok(parsed, 'transport/unknown error cannot establish payout baseline');
    simulation = { passed: false, error: parsed.name };
  }
  const staleOrFrozen = frozen || age > limits[7];
  if (staleOrFrozen) assert.equal(simulation.error, 'TickNotUsable');
  else assert.equal(simulation.passed, true, 'fresh baseline must permit payout');
  return { blockNumber: Number(BigInt(block.number)), blockHash: block.hash,
    blockTimeUtc: new Date(Number(BigInt(block.timestamp)) * 1000).toISOString(),
    holder, shares: '500000', acceptedTickId: latest[0],
    referenceTimeUtc: new Date(Number(latest[1][0]) * 1000).toISOString(),
    committedAtUtc: new Date(Number(latest[1][1]) * 1000).toISOString(),
    committedAgeSeconds: age, instantMaxTickAgeSeconds: limits[7], frozen, staleOrFrozen,
    simulation, readOnly: true };
}
async function revertAndCheckHead(local, snapshot, expected) {
  assert.equal(await local.send('evm_revert', [snapshot]), true);
  const restored = await local.send('eth_getBlockByNumber', ['latest', false]);
  for (const field of ['number', 'timestamp', 'hash']) assert.equal(restored[field], expected[field], 'fork head not restored: ' + field);
}
async function mineAt(local, timestamp) {
  const head = await local.send('eth_getBlockByNumber', ['latest', false]);
  const next = timestamp ?? Number(BigInt(head.timestamp)) + 1;
  await local.send('evm_setNextBlockTimestamp', [next]);
  await local.send('evm_mine', []);
}
async function send(local, owner, to, data, timestamp) {
  assert.ok(local.allowed);
  const nonce = await local.send('eth_getTransactionCount', [owner, 'latest']);
  const hash = await local.send('eth_sendTransaction', [{ from: owner, ...(to ? { to } : {}), data,
    value: '0x0', nonce, gas: E.toQuantity(20000000n),
    gasPrice: E.toQuantity(1000000000n + BigInt(++localTransactionSequence)) }]);
  await mineAt(local, timestamp);
  const receipt = await local.send('eth_getTransactionReceipt', [hash]);
  if (!receipt || BigInt(receipt.status) !== 1n) {
    let trace;
    try { trace = await local.send('debug_traceTransaction', [hash, { tracer: 'callTracer' }]); } catch {}
    fs.writeFileSync(path.join(out, 'local-failure.json'), json({ to, selector: data.slice(0, 10),
      transactionHash: hash, nonce, receipt, trace }) + '\n');
    throw new Error('local transaction failed: ' + (to || 'CREATE') + ' selector ' + data.slice(0, 10) +
      '; trace saved in ignored output');
  }
  return receipt;
}
async function strategyState(p, m, tag = 'latest') {
  const strategy = m.contracts.Strategy, agent = m.contracts.ChainAgent;
  const r = (name, args = []) => one(p, tag, strategy, si, name, args);
  const [name, symbol, decimals, asset, providersResult, entry, timelock, treasury, managementFee,
    performanceFee, minAssets, totalSupply, shares, totalAssets, lastAssets, lastTimestamp, healthy,
    proxyImpl, admin, idle, accrued] = await Promise.all([
    r('name'), r('symbol'), r('decimals'), r('asset'), r('getProviders'), r('getEntryProvider'),
    r('getTimelock'), r('getTreasury'), r('getManagementFee'), r('getPerformanceFee'), r('getMinAssets'),
    r('totalSupply'), r('balanceOf', [agent]), r('totalAssets'), r('getLastTotalAssets'), r('getLastTimestamp'),
    r('providersHealthy'), p.send('eth_getStorageAt', [strategy, implSlot, tag]),
    p.send('eth_getStorageAt', [strategy, adminSlot, tag]), one(p, tag, agent, agentAbi, 'idle'),
    call(p, tag, strategy, si, 'getAccruedFees'),
  ]);
  const providers = Array.from(providersResult);
  const holders = [...new Set([strategy, agent, treasury, m.deployer])];
  const balances = {}, roles = {}, caps = {}, sources = {}, providerBalances = {}, allowances = {}, assetBalances = {};
  for (const holder of holders) {
    balances[holder] = await r('balanceOf', [holder]);
    roles[holder] = { admin: await r('hasRole', [E.ZeroHash, holder]), executor: await r('hasRole', [E.id('EXECUTOR_ROLE'), holder]) };
    assetBalances[holder] = await one(p, tag, asset, tokenAbi, 'balanceOf', [holder]);
  }
  for (const provider of providers) {
    caps[provider] = await r('getProviderCap', [provider]);
    sources[provider] = await one(p, tag, provider, providerAbi, 'getSource', [asset, strategy, E.ZeroAddress]);
    providerBalances[provider] = await one(p, tag, provider, providerAbi, 'getDepositBalance', [strategy, strategy]);
    allowances[sources[provider]] = await one(p, tag, asset, tokenAbi, 'allowance', [strategy, sources[provider]]);
  }
  const prefixSlots = [];
  for (let slot = 0n; slot < 12n; slot++) prefixSlots.push(await p.send('eth_getStorageAt', [strategy, E.toBeHex(namespace + slot, 32), tag]));
  return { name, symbol, decimals, asset, providers, entry, timelock, treasury, managementFee, performanceFee,
    minAssets, totalSupply, shares, totalAssets, lastAssets, lastTimestamp, healthy,
    implementation: E.getAddress('0x' + proxyImpl.slice(-40)), proxyAdmin: E.getAddress('0x' + admin.slice(-40)),
    agentIdle: idle, accruedFeeShares: Array.from(accrued), balances, roles, caps, sources,
    providerBalances, allowances, assetBalances, prefixSlots };
}
function comparePreserved(before, after) {
  const keys = ['name', 'symbol', 'decimals', 'asset', 'providers', 'entry', 'timelock', 'treasury',
    'managementFee', 'performanceFee', 'minAssets', 'totalSupply', 'shares', 'proxyAdmin', 'agentIdle',
    'balances', 'roles', 'caps', 'sources', 'assetBalances'];
  for (const key of keys) assert.deepEqual(after[key], before[key], 'migration changed ' + key);
  assert.deepEqual(Object.keys(after.allowances), Object.keys(before.allowances), 'approval destinations changed');
  const allowanceRefreshes = [];
  for (const [source, previous] of Object.entries(before.allowances)) {
    const current = after.allowances[source];
    if (current === previous) continue;
    // _setProviders reapproves MAX to the same sources. USDC decrements even
    // a MAX allowance as it is spent; accept only this near-MAX refresh.
    assert.ok(previous >= E.MaxUint256 - 10n ** 18n && current === E.MaxUint256,
      'unexpected finite approval change for ' + source);
    allowanceRefreshes.push({ source, before: previous, after: current, spentAllowanceReapproved: current - previous });
  }
  for (const slot of [0, 1, 2, 3, 4, 5, 8, 9]) assert.equal(after.prefixSlots[slot], before.prefixSlots[slot], 'storage prefix slot changed: ' + slot);
  return { exactFields: keys, allowanceDestinationsPreserved: true, allowanceRefreshes };
}
function companion() {
  const dir = path.join(out, 'companion'); fs.mkdirSync(dir, { recursive: true });
  for (const name of ['strategy-value.ts', 'abi.ts', 'util.ts']) {
    fs.writeFileSync(path.join(dir, name), cp.execFileSync('git', ['show', COMPANION + ':ops/src/' + name], { cwd: root }));
  }
  require(path.join(deps, 'ops/node_modules/ts-node')).register({ transpileOnly: true, skipProject: true,
    compilerOptions: { module: 'CommonJS', target: 'ES2020', moduleResolution: 'node' } });
  return require(path.join(dir, 'strategy-value.ts'));
}
const companionOps = companion();
async function emptyProviderRecovery(local, m, state, provider) {
  assert.equal(state.providerBalances[provider], 0n);
  const gov = state.timelock;
  const target = m.contracts.Strategy;
  const unauthorized = await mustRevert(local, { from: m.deployer, to: target,
    data: si.encodeFunctionData('forceRemoveProvider', [provider]) }, 'Unauthorized');
  const readable = state.providers.find(p => p !== provider && p !== state.entry);
  const healthyRemoval = await mustRevert(local, { from: gov, to: target,
    data: si.encodeFunctionData('forceRemoveProvider', [readable]) }, 'ProviderStillReadable');
  const owner = await one(local, 'latest', gov, timelockAbi, 'owner');
  const delay = await one(local, 'latest', gov, timelockAbi, 'delay');
  await local.send('anvil_impersonateAccount', [owner]);
  await local.send('anvil_setBalance', [owner, E.toQuantity(E.parseEther('10'))]);
  const head = await local.send('eth_getBlockByNumber', ['latest', false]);
  const eta = Number(BigInt(head.timestamp) + delay + 120n);
  const args = [target, 0n, 'forceRemoveProvider(address)', E.AbiCoder.defaultAbiCoder().encode(['address'], [provider]), eta];
  const queued = await send(local, owner, gov, timelockAbi.encodeFunctionData('queue', args));
  const beforeEta = await mustRevert(local, { from: owner, to: gov,
    data: timelockAbi.encodeFunctionData('execute', args) }, 'Timelock__StillLocked');
  const executed = await send(local, owner, gov, timelockAbi.encodeFunctionData('execute', args), eta);
  const providers = Array.from(await one(local, 'latest', target, si, 'getProviders'));
  assert.deepEqual(providers, state.providers.filter(p => p !== provider));
  assert.equal(await one(local, 'latest', target, si, 'getEntryProvider'), state.entry);
  assert.equal(await one(local, 'latest', target, si, 'getPinnedProviderSource', [provider]), E.ZeroAddress);
  assert.equal(await one(local, 'latest', state.asset, tokenAbi, 'allowance', [target, state.sources[provider]]), 0n);
  assert.equal(await one(local, 'latest', target, si, 'providersHealthy'), true);
  const deallocated = await local.call({ from: m.deployer, to: m.contracts.ChainAgent,
    data: agentAbi.encodeFunctionData('deallocate', [state.minAssets]) });
  assert.ok(agentAbi.decodeFunctionResult('deallocate', deallocated)[0] > 0n);
  return { unauthorizedRemovalRejected: unauthorized, healthyRemovalRejected: healthyRemoval,
    delaySeconds: delay, blockedBeforeEta: beforeEta, queueHash: queued.transactionHash,
    executeHash: executed.transactionHash, exactProviderRemoved: true, entryPreserved: true,
    pinnedSourceCleared: true, approvalRevoked: true, completeNavRestored: true,
    deallocationSimulationPassed: true, writtenOffInitialAssets: '0', localWritesOnly: true };
}
async function checkOps(local, m, state) {
  const strategy = new E.Contract(m.contracts.Strategy, artifact.abi, local);
  let block = Number(BigInt((await local.send('eth_getBlockByNumber', ['latest', false])).number));
  const healthy = await companionOps.strategyShareValue(strategy, state.shares, block);
  const direct = await strategy.convertToAssets(state.shares, { blockTag: block });
  assert.equal(healthy.healthy, true); assert.equal(healthy.blocked, false); assert.equal(healthy.value, direct);
  const faults = [];
  for (const kind of ['empty-provider', 'funded-provider']) {
    const selected = state.providers.find(p => kind === 'empty-provider' ? state.providerBalances[p] === 0n : state.providerBalances[p] > 0n);
    if (!selected) { faults.push({ kind, skipped: 'no matching configured provider' }); continue; }
    const faultHead = await local.send('eth_getBlockByNumber', ['latest', false]);
    const snapshot = await local.send('evm_snapshot', []);
    try {
      await local.send('anvil_setCode', [selected, '0x60006000fd']);
      await mineAt(local);
      block = Number(BigInt((await local.send('eth_getBlockByNumber', ['latest', false])).number));
      assert.equal(await strategy.providersHealthy({ blockTag: block }), false);
      const currentMain = await mustRevert(local, { to: m.contracts.Strategy,
        data: si.encodeFunctionData('convertToAssets', [state.shares]) }, 'ProviderUnavailable');
      const exit = await mustRevert(local, { from: m.deployer, to: m.contracts.ChainAgent,
        data: agentAbi.encodeFunctionData('deallocate', [state.minAssets]) }, 'ProviderUnavailable');
      const deposit = await mustRevert(local, { from: m.contracts.ChainAgent, to: m.contracts.Strategy,
        data: si.encodeFunctionData('deposit', [state.minAssets, m.contracts.ChainAgent]) }, 'ProviderUnavailable');
      const readable = await companionOps.strategyShareValue(strategy, state.shares, block);
      assert.equal(readable.healthy, false); assert.equal(readable.blocked, true);
      assert.ok(readable.readable.failing.map(x => x.toLowerCase()).includes(selected.toLowerCase()));
      if (kind === 'empty-provider') assert.ok(readable.value > 0n);
      let recovery, entryRemoval;
      if (si.hasFunction('forceRemoveProvider')) {
        if (kind === 'empty-provider') recovery = await emptyProviderRecovery(local, m, state, selected);
        else if (selected === state.entry) entryRemoval = await mustRevert(local,
          { from: state.timelock, to: m.contracts.Strategy,
            data: si.encodeFunctionData('forceRemoveProvider', [selected]) }, 'ProviderIsEntry');
      }
      faults.push({ kind, provider: selected, currentMainOpsConvertFirstFails: currentMain,
        companionContinues: true, readableShareValue: readable.value, readableTotal: readable.readable.total,
        failing: readable.readable.failing, settlementStillBlocked: exit.reverted && deposit.reverted,
        deallocationRevert: exit, depositRevert: deposit, timelockedRecovery: recovery,
        entryForceRemovalRejected: entryRemoval });
    } finally { await revertAndCheckHead(local, snapshot, faultHead); }
  }
  return { companionCommit: COMPANION, healthyValueMatchesContract: true, faults,
    productionServiceCompatibilityAttested: false };
}
async function legacyEmptyProviderExit(local, m, state) {
  const selected = state.providers.find(provider => state.providerBalances[provider] === 0n);
  if (!selected) return { skipped: 'no empty provider' };
  const faultHead = await local.send('eth_getBlockByNumber', ['latest', false]);
  const snapshot = await local.send('evm_snapshot', []);
  try {
    await local.send('anvil_setCode', [selected, '0x60006000fd']); await mineAt(local);
    try {
      await local.call({ from: m.deployer, to: m.contracts.ChainAgent,
        data: agentAbi.encodeFunctionData('deallocate', [state.minAssets]) });
      return { provider: selected, exitSimulationPassed: true, liveWrites: false };
    } catch (e) {
      const data = revertData(e);
      assert.ok(typeof data === 'string' || /revert/i.test(e?.info?.error?.message || ''), 'RPC error cannot prove legacy behavior');
      return { provider: selected, exitSimulationPassed: false, revertData: data, liveWrites: false };
    }
  } finally { await revertAndCheckHead(local, snapshot, faultHead); }
}
async function financialPaths(local, m, migrated, baseline) {
  const owner = m.deployer, agent = m.contracts.ChainAgent, strategy = m.contracts.Strategy;
  const amount = migrated.minAssets;
  assert.ok(await one(local, 'latest', strategy, si, 'convertToAssets', [migrated.shares]) > amount);
  const deallocate = await send(local, owner, agent, agentAbi.encodeFunctionData('deallocate', [amount]));
  assert.equal(await one(local, 'latest', agent, agentAbi, 'idle'), migrated.agentIdle + amount);
  let returned, pushed, paid;
  if (m.contracts.EpochVault) {
    const vault = m.contracts.EpochVault;
    const cashBefore = (await call(local, 'latest', vault, vaultAbi, 'accounting'))[0];
    returned = await send(local, owner, agent, agentAbi.encodeFunctionData('returnToVault', [amount]));
    assert.equal((await call(local, 'latest', vault, vaultAbi, 'accounting'))[0], cashBefore + amount);
    pushed = await send(local, owner, vault, vaultAbi.encodeFunctionData('pushToAgent', [amount]));
    assert.equal((await call(local, 'latest', vault, vaultAbi, 'accounting'))[0], cashBefore);
  }
  const allocation = await send(local, owner, agent, agentAbi.encodeFunctionData('allocate', [amount]));
  assert.equal(await one(local, 'latest', agent, agentAbi, 'idle'), migrated.agentIdle);
  const valueAfter = await one(local, 'latest', strategy, si, 'convertToAssets', [await one(local, 'latest', agent, agentAbi, 'strategyShares')]);
  const valueBefore = await one(local, 'latest', strategy, si, 'convertToAssets', [migrated.shares]);
  assert.ok(valueAfter + 20n >= valueBefore, 'unexpected round-trip asset loss');
  if (m.contracts.EpochVault) {
    const vault = m.contracts.EpochVault;
    const holder = baseline.holder;
    const afterBaseline = await payoutBaseline(local, m, 'latest', holder);
    if (!baseline.simulation.passed) {
      assert.equal(afterBaseline.simulation.error, baseline.simulation.error, 'upgrade changed payout gate');
      paid = { executed: false, operationalGatePreserved: true, beforeUpgrade: baseline,
        afterUpgrade: afterBaseline, positivePayoutEvidence: 'separate pinned fresh-state fork required' };
    } else {
      assert.equal(afterBaseline.simulation.passed, true, 'payout became unavailable after migration');
      await local.send('anvil_impersonateAccount', [holder]);
      await local.send('anvil_setBalance', [holder, E.toQuantity(E.parseEther('1'))]);
      const userBefore = await one(local, 'latest', migrated.asset, tokenAbi, 'balanceOf', [holder]);
      const cashBefore = (await call(local, 'latest', vault, vaultAbi, 'accounting'))[0];
      const receipt = await send(local, holder, vault, vaultAbi.encodeFunctionData('instantRedeem', [500000n, holder, holder, 1n]));
      const userAfter = await one(local, 'latest', migrated.asset, tokenAbi, 'balanceOf', [holder]);
      const cashAfter = (await call(local, 'latest', vault, vaultAbi, 'accounting'))[0];
      const buffer = await one(local, 'latest', vault, vaultAbi, 'minimumBuffer');
      assert.ok(userAfter > userBefore); assert.equal(userAfter - userBefore, cashBefore - cashAfter);
      assert.ok(cashAfter < buffer, 'payout did not cross the allocation floor');
      paid = { executed: true, holder, assetsPaid: userAfter - userBefore, remainingCash: cashAfter, allocationFloor: buffer,
        receiptHash: receipt.transactionHash };
    }
  }
  return { amount, deallocationPassed: true, allocationPassed: true, zeroResidualIdle: true,
    deallocationHash: deallocate.transactionHash, allocationHash: allocation.transactionHash,
    returnToVaultPassed: Boolean(returned), pushBackToAgentPassed: Boolean(pushed), instantPayout: paid };
}
async function fork(network, url, chainId, mode = 'full') {
  const faultsOnly = mode === 'fault-exits';
  const req = new E.FetchRequest(url); req.timeout = 20000;
  const publicRpc = new ReadOnlyProvider(req, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  const m = JSON.parse(fs.readFileSync(path.join(root, 'deployments', network, 'crosschain.json')));
  let child, local, snapshot, ended = false;
  let report;
  try {
    status(network, 'read-only production attestation');
    assert.equal(BigInt(await publicRpc.send('eth_chainId', [])), BigInt(chainId));
    const pinned = mode === 'fresh-payout' ? JSON.parse(fs.readFileSync(path.join(__dirname, 'baseline-106e905/base-fork-verification.json'))) : undefined;
    const head = await publicRpc.send('eth_getBlockByNumber', [pinned ? E.toQuantity(pinned.forkBlock) : 'latest', false]);
    if (pinned) { assert.equal(network, 'base'); assert.equal(head.hash, pinned.forkBlockHash); }
    const payout = await payoutBaseline(publicRpc, m, head.number);
    if (payout && !pinned) save('base-live-payout-baseline.json', payout);
    if (pinned) assert.equal(payout.simulation.passed, true, 'known-state payout no longer reproduces');
    if (mode === 'baseline') { status(network, 'read-only live payout baseline recorded'); return; }
    const live = await strategyState(publicRpc, m, head.number);
    assert.equal(live.implementation, m.contracts.StrategyImplementation);
    const liveCode = await publicRpc.send('eth_getCode', [live.implementation, head.number]);
    assert.equal(E.keccak256(liveCode), build.legacyRuntimeHash);
    assert.equal(live.prefixSlots[10], E.ZeroHash, 'new HWM slot not empty');
    assert.equal(live.prefixSlots[11], E.ZeroHash, 'new source mapping root not empty');
    assert.equal(new Set(Object.values(live.sources).map(x => x.toLowerCase())).size, live.providers.length, 'existing provider/source aliases');
    assert.equal(await one(publicRpc, head.number, live.proxyAdmin, adminAbi, 'owner'), m.deployer);
    const probe = net.createServer();
    await new Promise((resolve, reject) => { probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve); });
    const port = probe.address().port;
    await new Promise((resolve, reject) => probe.close(e => e ? reject(e) : resolve()));
    child = cp.spawn(process.env.ANVIL_BINARY || 'anvil', ['--host', '127.0.0.1', '--port', String(port),
      '--chain-id', String(chainId), '--fork-url', url, '--fork-block-number', String(Number(BigInt(head.number))),
      '--no-fork-node-info', '--no-bal', '--silent'],
      { cwd: out, stdio: 'ignore', env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR } });
    child.on('exit', () => { ended = true; });
    child.on('error', () => { ended = true; });
    local = new LocalProvider('http://127.0.0.1:' + port);
    for (let i = 0; i < 120; i++) {
      assert.equal(ended, false, 'local Anvil exited before readiness');
      try {
        assert.match(await local.send('web3_clientVersion', []), /anvil/i);
        assert.equal(BigInt(await local.send('eth_chainId', [])), BigInt(chainId));
        local.allowed = true; break;
      } catch { await pause(250); }
    }
    assert.equal(local.allowed, true, 'local Anvil unavailable');
    assert.equal((await local.send('eth_getBlockByNumber', [head.number, false])).hash, head.hash);
    snapshot = await local.send('evm_snapshot', []);
    // Manual one-second blocks keep time deterministic after reverting a test
    // that advances through the Timelock's full 24h delay.
    await local.send('evm_setAutomine', [false]);
    await local.send('anvil_impersonateAccount', [m.deployer]);
    await local.send('anvil_setBalance', [m.deployer, E.toQuantity(E.parseEther('10'))]);
    status(network, 'local target deployment and migration');
    const before = await strategyState(local, m);
    const legacyExit = await legacyEmptyProviderExit(local, m, before);
    const deployment = await send(local, m.deployer, undefined, artifact.bytecode);
    const nextImplementation = deployment.contractAddress;
    assert.equal(E.keccak256(await local.send('eth_getCode', [nextImplementation, 'latest'])), build.targetRuntimeHash);
    const bareState = await local.send('evm_snapshot', []);
    await send(local, m.deployer, live.proxyAdmin, adminAbi.encodeFunctionData('upgradeAndCall', [m.contracts.Strategy, nextImplementation, '0x']));
    const bareUpgrade = await mustRevert(local, { to: m.contracts.Strategy,
      data: si.encodeFunctionData('convertToAssets', [before.shares]) }, ['SecurityAccountingNotInitialized', 'ProviderUnavailable']);
    const assetsNow = before.totalAssets + before.assetBalances[m.contracts.Strategy];
    const minimumPps = (assetsNow * 10n ** 18n + before.totalSupply - 1n) / before.totalSupply;
    const testHwm = minimumPps + 10n ** 12n; // local test only; never a historic attestation.
    const init = si.encodeFunctionData('initializeSecurityAccounting', [testHwm]);
    const unauthorized = await mustRevert(local, { from: '0x0000000000000000000000000000000000001234',
      to: m.contracts.Strategy, data: init }, 'Unauthorized');
    assert.equal(await local.send('evm_revert', [bareState]), true);
    const lowHwm = await mustRevert(local, { from: m.deployer, to: live.proxyAdmin,
      data: adminAbi.encodeFunctionData('upgradeAndCall', [m.contracts.Strategy, nextImplementation,
        si.encodeFunctionData('initializeSecurityAccounting', [0])]) }, 'InvalidInput');
    const migratedReceipt = await send(local, m.deployer, live.proxyAdmin,
      adminAbi.encodeFunctionData('upgradeAndCall', [m.contracts.Strategy, nextImplementation, init]));
    const after = await strategyState(local, m);
    const preserved = comparePreserved(before, after);
    assert.equal(after.implementation, E.getAddress(nextImplementation));
    assert.equal(await one(local, 'latest', m.contracts.Strategy, si, 'getHighWaterMark'), testHwm);
    for (const provider of before.providers) assert.equal(await one(local, 'latest', m.contracts.Strategy, si,
      'getPinnedProviderSource', [provider]), before.sources[provider]);
    const repeat = await mustRevert(local, { from: m.deployer, to: live.proxyAdmin,
      data: adminAbi.encodeFunctionData('upgradeAndCall', [m.contracts.Strategy, nextImplementation, init]) }, 'InvalidInitialization');
    status(network, 'provider-failure compatibility and funds round trip');
    const ops = await checkOps(local, m, after);
    const paths = faultsOnly ? undefined : await financialPaths(local, m, after, payout);
    report = { network, chainId, targetCommit: build.targetCommit, liveWrites: false,
      forkBlock: Number(BigInt(head.number)), forkBlockHash: head.hash, liveState: live,
      localImplementation: nextImplementation, localMigrationHash: migratedReceipt.transactionHash,
      localMigrationGasUsed: BigInt(migratedReceipt.gasUsed), historicalHwmAttested: false,
      localTestHwm: testHwm, minimumCurrentPpsAtObservation: minimumPps,
      legacyUnsettledFeeSharesWaivedAtMigration: before.accruedFeeShares,
      preserved, before, after, bareUpgradeFails: bareUpgrade, unauthorizedInitializerFails: unauthorized,
      lowHwmFails: lowHwm, repeatedInitializerFails: repeat, sourcePinsMatch: true,
      ops, financialPaths: paths, legacyEmptyProviderExit: legacyExit,
      payoutBeforeUpgrade: payout, timeWarpSnapshotsRestoreHead: true,
      scope: faultsOnly ? 'provider-failure financial-operation extension' : pinned
        ? 'latest target migration and actual user payout at a pinned fresh production state'
        : 'live-head migration, funds round trip and existing payout gate comparison' };
  } finally {
    try {
      if (local && snapshot !== undefined) {
        const reverted = await local.send('evm_revert', [snapshot]);
        assert.equal(reverted, true); if (report) report.snapshotReverted = true;
      }
    } finally {
      local?.destroy(); publicRpc.destroy();
      if (child && !ended) { child.kill('SIGTERM'); for (let i = 0; !ended && i < 30; i++) await pause(100); }
      if (child) assert.ok(ended, 'local Anvil not stopped');
      if (report) { report.localNodeStopped = true;
        save(network + (faultsOnly ? '-fault-exit-verification.json' : mode === 'fresh-payout'
          ? '-fresh-payout-verification.json' : '-fork-verification.json'), report); }
    }
  }
  status(network, 'fork verification passed; snapshot restored and node stopped');
}
async function main() {
  const selection = process.argv[2] || 'both';
  assert.ok(['base', 'arbitrum', 'both'].includes(selection));
  const mode = process.argv[3] || 'full';
  assert.ok(['full', 'fault-exits', 'fresh-payout', 'baseline'].includes(mode));
  if (['fresh-payout', 'baseline'].includes(mode)) assert.equal(selection, 'base');
  if (selection !== 'arbitrum') await fork('base', 'https://mainnet.base.org', 8453, mode);
  if (selection !== 'base') await fork('arbitrum', 'https://arb1.arbitrum.io/rpc', 42161, mode);
}
main().catch(e => {
  console.error('Readiness fork check failed: ' + (e.code || 'audit error') + ': ' +
    String(e?.info?.error?.message || e?.error?.message || e.shortMessage || e.message || '')
      .replace(/https?:\/\/[^\s"']+/g, '[RPC]').slice(0, 900));
  process.exitCode = 1;
});
