import assert from 'node:assert/strict';
import { test } from 'node:test';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { AbiCoder, Interface, getAddress, keccak256 } from 'ethers';
import { BASE_STRATEGY, LEGACY_RUNTIME_HASH, TARGET_RUNTIME_HASH, assertArtifactCoherence, buildBaseUpgradePlan, ceilingPps,
  type BaseUpgradeInputs, type BaseUpgradeSnapshot, type UpgradeCandidate,
} from '../../scripts/prepare-base-crosschain-upgrade';
import { ReadOnlyRpc } from '../../scripts/prepare-gauntlet-v2-deploy';

const a = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`);
const snapshot = (): BaseUpgradeSnapshot => ({
  chainId: 8453, block: 1, blockHash: keccak256('0x01'), timestamp: 1_800_000_000, profile: 'stand',
  proxy: BASE_STRATEGY, implementation: a(10), manifestImplementation: a(10),
  implementationRuntimeHash: LEGACY_RUNTIME_HASH, manifestRuntimeHash: LEGACY_RUNTIME_HASH,
  proxyAdmin: a(11), proxyAdminOwner: a(12), adminInterfaceVersion: '5.0.0',
  timelock: a(13), timelockOwner: a(14), delay: 86400, asset: a(15), treasury: a(16),
  managementFee: '0', performanceFee: '0', totalAssets: '101', totalSupply: '100', healthy: true,
  entryProvider: a(20), providers: [20, 21, 22, 23, 24].map((n, i) => ({
    address: a(n), source: a(n + 100), runtimeHash: keccak256('0x01'), sourceRuntimeHash: keccak256('0x02'),
    identifier: `original-${i}`, assets: String(i * 100), capBps: i === 0 ? 0 : 7000,
  })),
});
const inputs = (): BaseUpgradeInputs => ({ historicalHwm: '1100000000000000000',
  attestHistoricalHwm: true, attestProviderSources: true, acceptLegacyFeeWaiver: true,
  hwmEvidence: 'governance/reviewed-historical-pps.json', providerSourcesEvidence: 'governance/reviewed-sources.json',
  fluidCapBps: 3000, morphoV2CapBps: 2000 });
const candidates = (): UpgradeCandidate[] => ['Rebalancer', 'FluidProvider', 'MorphoV2Provider'].map((name, i) => ({
  name, address: a(30 + i), source: [undefined, getAddress('0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169'),
    getAddress('0x050cE30b927Da55177A4914EC73480238BAD56f0')][i],
  expectedRuntimeHash: i === 0 ? TARGET_RUNTIME_HASH : keccak256('0x01'),
  runtimeVerified: true, sourceVerified: true,
  unsignedDeployment: { chainId: 8453, value: '0', data: '0x6000' },
}));

test('atomic upgrade carries the explicit migration and actual owner; no bare upgrade', () => {
  const s = snapshot();
  const plan = buildBaseUpgradePlan(s, candidates(), inputs());
  assert.equal(plan.status, 'UNSIGNED_READY_FOR_FORK_AND_HUMAN_REVIEW');
  assert.equal(plan.atomicUpgrade?.from, s.proxyAdminOwner);
  assert.equal(plan.atomicUpgrade?.to, s.proxyAdmin);
  const upgrade = new Interface(['function upgradeAndCall(address,address,bytes) payable'])
    .decodeFunctionData('upgradeAndCall', plan.atomicUpgrade!.data);
  assert.equal(upgrade[0], BASE_STRATEGY);
  assert.equal(upgrade[1], a(30));
  const migration = new Interface(['function initializeSecurityAccounting(uint256)'])
    .decodeFunctionData('initializeSecurityAccounting', upgrade[2]);
  assert.equal(migration[0], BigInt(inputs().historicalHwm!));
});

test('registration appends both venues without replacing any funded provider or entry', () => {
  const s = snapshot();
  const before = JSON.stringify(s);
  const plan = buildBaseUpgradePlan(s, candidates(), inputs());
  assert.deepEqual(plan.nextProviders, [...s.providers.map((p) => p.address), a(31), a(32)]);
  assert.deepEqual(plan.preserve.providers, s.providers);
  assert.equal(plan.preserve.entryProvider, s.entryProvider);
  assert.equal(JSON.stringify(s), before, 'Builder must not mutate its snapshot');
  const first = plan.governance[0];
  const tl = new Interface(['function queue(address,uint256,string,bytes,uint256)',
    'function execute(address,uint256,string,bytes,uint256)', 'function cancel(address,uint256,string,bytes,uint256)']);
  const tuple = Array.from(tl.decodeFunctionData('queue', first.queue.data));
  assert.equal(first.queue.from, s.timelockOwner);
  assert.equal(first.queue.to, s.timelock);
  assert.equal(tuple[0], BASE_STRATEGY);
  assert.equal(tuple[2], 'setProviders(address[])');
  assert.deepEqual(Array.from(AbiCoder.defaultAbiCoder().decode(['address[]'], tuple[3])[0]), plan.nextProviders);
  assert.equal(tuple[4], BigInt(s.timestamp + s.delay + 3600));
  assert.deepEqual(Array.from(tl.decodeFunctionData('execute', first.execute.data)), tuple);
  assert.deepEqual(Array.from(tl.decodeFunctionData('cancel', first.cancel.data)), tuple);
  assert.equal(first.transactionId, keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], tuple)));
  for (const [i, cap] of [3000n, 2000n].entries()) {
    const decoded = AbiCoder.defaultAbiCoder().decode(['address', 'uint256'], plan.governance[i + 1].data);
    assert.equal(decoded[0], a(31 + i));
    assert.equal(decoded[1], cap);
  }
});

test('unknown evidence, caps or deployment addresses never produce executable calldata', () => {
  for (const missing of ['historicalHwm', 'attestHistoricalHwm', 'attestProviderSources',
    'acceptLegacyFeeWaiver', 'hwmEvidence', 'providerSourcesEvidence', 'fluidCapBps', 'morphoV2CapBps'] as const) {
    const options = { ...inputs(), [missing]: missing.startsWith('attest') || missing.startsWith('accept') ? false : undefined };
    const plan = buildBaseUpgradePlan(snapshot(), candidates(), options);
    assert.equal(plan.status, 'DRAFT_NOT_SIGNABLE', missing);
    assert.equal(plan.atomicUpgrade, null, missing);
    assert.equal(plan.nextProviders, null, missing);
    assert.deepEqual(plan.governance, [], missing);
    assert.ok(plan.blockers.length);
  }
  for (const index of [0, 1, 2]) {
    const proposed = candidates();
    proposed[index].address = undefined;
    proposed[index].runtimeVerified = false;
    const plan = buildBaseUpgradePlan(snapshot(), proposed, inputs());
    assert.equal(plan.atomicUpgrade, null);
    assert.deepEqual(plan.governance, []);
    assert.ok(plan.blockers.some((b) => /actual deployed address/.test(b)));
  }
});

test('wrong chain, manifest target, legacy runtime and governance generation fail closed', () => {
  const bad: Partial<BaseUpgradeSnapshot>[] = [
    { chainId: 42161 }, { proxy: a(99) }, { profile: 'unknown' }, { implementation: a(99) },
    { implementationRuntimeHash: keccak256('0x12') }, { manifestRuntimeHash: keccak256('0x12') },
    { adminInterfaceVersion: '4.9.0' }, { healthy: false }, { delay: 0 }, { proxyAdmin: a(0) },
  ];
  for (const change of bad) assert.throws(() => buildBaseUpgradePlan({ ...snapshot(), ...change }, candidates(), inputs()));
});

test('HWM rounds up with no floating point and cannot be guessed or too low', () => {
  assert.equal(ceilingPps('1', '3'), 333333333333333334n);
  for (const hwm of ['0', '1', '1009999999999999999', '-1', '1.1', '1e18']) {
    assert.throws(() => buildBaseUpgradePlan(snapshot(), candidates(), { ...inputs(), historicalHwm: hwm }));
  }
  assert.throws(() => ceilingPps('1', '0'), /Zero Strategy supply/);
  assert.equal(buildBaseUpgradePlan(snapshot(), candidates(), { ...inputs(), historicalHwm: '1010000000000000000' }).blockers.length, 0);
});

test('duplicate source aliases, capped/missing entry and wrong-chain candidates are rejected', () => {
  const s = snapshot();
  s.providers[1].source = s.providers[0].source;
  assert.throws(() => buildBaseUpgradePlan(s, candidates(), inputs()), /Duplicate/);
  const entry = snapshot();
  entry.providers[0].capBps = 1;
  assert.throws(() => buildBaseUpgradePlan(entry, candidates(), inputs()), /uncapped/);
  const proposed = candidates();
  proposed[1].source = snapshot().providers[0].source;
  assert.throws(() => buildBaseUpgradePlan(snapshot(), proposed, inputs()), /Base registry/);
  proposed[1].source = candidates()[1].source;
  proposed[1].unsignedDeployment.chainId = 1;
  assert.throws(() => buildBaseUpgradePlan(snapshot(), proposed, inputs()), /Base only/);
  for (const cap of [0, -1, 10001, NaN, 1.5]) assert.throws(() => buildBaseUpgradePlan(snapshot(), candidates(), { ...inputs(), fluidCapBps: cap }), /caps/);
});

test('incorrect candidate source, target runtime or unconfigured caps never become reviewable', () => {
  const proposed = candidates();
  proposed[0].expectedRuntimeHash = keccak256('0x12');
  assert.throws(() => buildBaseUpgradePlan(snapshot(), proposed, inputs()), /reviewed main build/);
  proposed[0] = candidates()[0];
  proposed[1].source = undefined;
  assert.throws(() => buildBaseUpgradePlan(snapshot(), proposed, inputs()), /source is missing/);
  assert.throws(() => buildBaseUpgradePlan(snapshot(), candidates(), { ...inputs(), fluidCapBps: 2500 }), /Base registry/);
});

test('extra existing providers stay in place rather than being reset to registry count', () => {
  const s = snapshot();
  s.providers.push({ ...s.providers[1], address: a(25), source: a(125) });
  assert.deepEqual(buildBaseUpgradePlan(s, candidates(), inputs()).nextProviders,
    [...s.providers.map((p) => p.address), a(31), a(32)]);
});

test('preparation rejects broadcasting and mutating RPC at both RPC boundaries', async () => {
  const rpc = new ReadOnlyRpc('http://127.0.0.1:1', 8453, { staticNetwork: true });
  try {
    for (const method of ['eth_sendTransaction', 'eth_sendRawTransaction', 'eth_sign', 'personal_sign', 'anvil_setCode']) {
      await assert.rejects(rpc.send(method, []), /Preparation forbids/);
      await assert.rejects(rpc._send({ method, params: [], id: 1, jsonrpc: '2.0' }), /Preparation forbids/);
    }
  } finally { rpc.destroy(); }
});

test('CLI rejects execution flags before artifacts or RPC access', () => {
  const script = path.resolve(__dirname, '../../scripts/prepare-base-crosschain-upgrade.ts');
  for (const flag of ['--send', '--execute', '--network', '--private-key']) {
    const result = spawnSync(process.execPath,
      ['--require', 'ts-node/register/transpile-only', script, flag], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /cannot deploy, sign or send/);
  }
});

test('ABI and both bytecodes must belong to the referenced compiler output', () => {
  const artifact = { contractName: 'Candidate', abi: [], bytecode: '0x6000', deployedBytecode: '0x6001' };
  const compiled = { abi: [], evm: { bytecode: { object: '6000' }, deployedBytecode: { object: '6001' } } };
  assert.doesNotThrow(() => assertArtifactCoherence(artifact, compiled));
  assert.throws(() => assertArtifactCoherence({ ...artifact, bytecode: '0x6002' }, compiled), /compiler build output/);
  assert.throws(() => assertArtifactCoherence({ ...artifact, deployedBytecode: '0x6002' }, compiled), /compiler build output/);
  assert.throws(() => assertArtifactCoherence({ ...artifact, abi: [{ type: 'error', name: 'Extra', inputs: [] }] }, compiled), /compiler build output/);
});
