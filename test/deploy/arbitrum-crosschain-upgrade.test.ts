import assert from 'node:assert/strict';
import { test } from 'node:test';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { AbiCoder, Interface, getAddress, keccak256 } from 'ethers';
import { ARBITRUM_STRATEGY, LEGACY_RUNTIME_HASH, TARGET_RUNTIME_HASH, assertArtifactCoherence, buildArbitrumUpgradePlan, ceilingPps,
  type ArbitrumUpgradeInputs, type ArbitrumUpgradeSnapshot, type UpgradeCandidate,
} from '../../scripts/prepare-arbitrum-crosschain-upgrade';
import { ReadOnlyRpc } from '../../scripts/prepare-gauntlet-v2-deploy';

const a = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`);
const legacy = [
  ['0xA34574Dae6284EDc7348C36A80242b92CFBd13A5', '0x794a61358D6845594F94dc1DB02A252b5b4814aD', 0],
  ['0x9eE0a4d3d9f4172FEB7E518EBbd73AF9a5E16664', '0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf', 5000],
  ['0xeB98d46937C537efF376361536D58d78c57c40d7', '0x7e97fa6893871a2751b5fe961978dccb2c201e65', 4000],
  ['0x6240402d3Cb33777D4E5E6B5791bC8518AEb8B99', '0x5c0c306aaa9f877de636f4d5822ca9f2e81563ba', 3000],
  ['0x0D9FD60E25b0C3b2416D46F7dd311b0ED6743484', '0x250cf7c82bac7cb6cf899b6052979d4b5ba1f9ca', 4000],
] as const;
const snapshot = (): ArbitrumUpgradeSnapshot => ({
  chainId: 42161, block: 526524948, blockHash: keccak256('0x01'), timestamp: 1_800_000_000, profile: 'stand',
  proxy: ARBITRUM_STRATEGY, implementation: '0x84163d2d9CFfe0e53078C3Cd02ee3db1975117d5',
  manifestImplementation: '0x84163d2d9CFfe0e53078C3Cd02ee3db1975117d5',
  implementationRuntimeHash: LEGACY_RUNTIME_HASH, manifestRuntimeHash: LEGACY_RUNTIME_HASH,
  proxyAdmin: a(11), proxyAdminOwner: a(12), adminInterfaceVersion: '5.0.0',
  timelock: a(13), timelockOwner: a(14), delay: 86400,
  asset: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', treasury: a(16),
  managementFee: '0', performanceFee: '0', totalAssets: '101', totalSupply: '100', healthy: true,
  entryProvider: legacy[0][0], providers: legacy.map(([address, source, capBps], i) => ({
    address: getAddress(address), source: getAddress(source),
    runtimeHash: keccak256('0x01'), sourceRuntimeHash: keccak256('0x02'),
    identifier: `original-${i}`, assets: String(i * 100), capBps,
  })),
});
const inputs = (): ArbitrumUpgradeInputs => ({ historicalHwm: '1100000000000000000',
  attestHistoricalHwm: true, attestProviderSources: true, acceptLegacyFeeWaiver: true,
  hwmEvidence: 'governance/reviewed-historical-pps.json', providerSourcesEvidence: 'governance/reviewed-sources.json',
  fluidCapBps: 3000, morphoV2CapBps: 2000 });
const candidates = (): UpgradeCandidate[] => ['Rebalancer', 'FluidProvider', 'MorphoV2Provider'].map((name, i) => ({
  name, address: a(30 + i), source: [undefined, getAddress('0x1A996cb54bb95462040408C06122D45D6Cdb6096'),
    getAddress('0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78')][i],
  expectedRuntimeHash: i === 0 ? TARGET_RUNTIME_HASH : keccak256('0x01'),
  runtimeVerified: true, sourceVerified: true,
  unsignedDeployment: { chainId: 42161, value: '0', data: '0x6000' },
}));

test('atomic upgrade carries the explicit migration and actual owner; no bare upgrade', () => {
  const s = snapshot();
  const plan = buildArbitrumUpgradePlan(s, candidates(), inputs());
  assert.equal(plan.status, 'UNSIGNED_READY_FOR_FORK_AND_HUMAN_REVIEW');
  assert.equal(plan.atomicUpgrade?.from, s.proxyAdminOwner);
  assert.equal(plan.atomicUpgrade?.to, s.proxyAdmin);
  const upgrade = new Interface(['function upgradeAndCall(address,address,bytes) payable'])
    .decodeFunctionData('upgradeAndCall', plan.atomicUpgrade!.data);
  assert.equal(upgrade[0], ARBITRUM_STRATEGY);
  assert.equal(upgrade[1], a(30));
  const migration = new Interface(['function initializeSecurityAccounting(uint256)'])
    .decodeFunctionData('initializeSecurityAccounting', upgrade[2]);
  assert.equal(migration[0], BigInt(inputs().historicalHwm!));
});

test('registration appends both venues without replacing any funded provider or entry', () => {
  const s = snapshot();
  const before = JSON.stringify(s);
  const plan = buildArbitrumUpgradePlan(s, candidates(), inputs());
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
  assert.equal(tuple[0], ARBITRUM_STRATEGY);
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
    const plan = buildArbitrumUpgradePlan(snapshot(), candidates(), options);
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
    const plan = buildArbitrumUpgradePlan(snapshot(), proposed, inputs());
    assert.equal(plan.atomicUpgrade, null);
    assert.deepEqual(plan.governance, []);
    assert.ok(plan.blockers.some((b) => /actual deployed address/.test(b)));
  }
});

test('wrong chain, manifest target, legacy runtime and governance generation fail closed', () => {
  const bad: Partial<ArbitrumUpgradeSnapshot>[] = [
    { chainId: 8453 }, { proxy: a(99) }, { profile: 'unknown' }, { implementation: a(99) },
    { implementationRuntimeHash: keccak256('0x12') }, { manifestRuntimeHash: keccak256('0x12') },
    { adminInterfaceVersion: '4.9.0' }, { healthy: false }, { delay: 0 }, { proxyAdmin: a(0) },
  ];
  for (const change of bad) assert.throws(() => buildArbitrumUpgradePlan({ ...snapshot(), ...change }, candidates(), inputs()));
});

test('HWM rounds up with no floating point and cannot be guessed or too low', () => {
  assert.equal(ceilingPps('1', '3'), 333333333333333334n);
  for (const hwm of ['0', '1', '1009999999999999999', '-1', '1.1', '1e18']) {
    assert.throws(() => buildArbitrumUpgradePlan(snapshot(), candidates(), { ...inputs(), historicalHwm: hwm }));
  }
  assert.throws(() => ceilingPps('1', '0'), /Zero Strategy supply/);
  assert.equal(buildArbitrumUpgradePlan(snapshot(), candidates(), { ...inputs(), historicalHwm: '1010000000000000000' }).blockers.length, 0);
});

test('duplicate source aliases, capped/missing entry and wrong-chain candidates are rejected', () => {
  const s = snapshot();
  s.providers[1].source = s.providers[0].source;
  assert.throws(() => buildArbitrumUpgradePlan(s, candidates(), inputs()), /Duplicate/);
  const entry = snapshot();
  entry.providers[0].capBps = 1;
  assert.throws(() => buildArbitrumUpgradePlan(entry, candidates(), inputs()), /source.cap drift/);
  const proposed = candidates();
  proposed[1].source = snapshot().providers[0].source;
  assert.throws(() => buildArbitrumUpgradePlan(snapshot(), proposed, inputs()), /Arbitrum registry/);
  proposed[1].source = candidates()[1].source;
  proposed[1].unsignedDeployment.chainId = 1;
  assert.throws(() => buildArbitrumUpgradePlan(snapshot(), proposed, inputs()), /Arbitrum only/);
  for (const cap of [0, -1, 10001, NaN, 1.5]) assert.throws(() => buildArbitrumUpgradePlan(snapshot(), candidates(), { ...inputs(), fluidCapBps: cap }), /caps/);
});

test('incorrect candidate source, target runtime or unconfigured caps never become reviewable', () => {
  const proposed = candidates();
  proposed[0].expectedRuntimeHash = keccak256('0x12');
  assert.throws(() => buildArbitrumUpgradePlan(snapshot(), proposed, inputs()), /reviewed main build/);
  proposed[0] = candidates()[0];
  proposed[1].source = undefined;
  assert.throws(() => buildArbitrumUpgradePlan(snapshot(), proposed, inputs()), /source is missing/);
  assert.throws(() => buildArbitrumUpgradePlan(snapshot(), candidates(), { ...inputs(), fluidCapBps: 2500 }), /Arbitrum registry/);
});

test('provider order, source, cap, chain and native asset drift cannot silently replace the reviewed deployment', () => {
  const mutations = [
    (s: ArbitrumUpgradeSnapshot) => s.providers.push({ ...s.providers[1], address: a(25), source: a(125) }),
    (s: ArbitrumUpgradeSnapshot) => s.providers.reverse(),
    (s: ArbitrumUpgradeSnapshot) => { s.providers[1].source = a(125); },
    (s: ArbitrumUpgradeSnapshot) => { s.providers[1].capBps = 0; },
    (s: ArbitrumUpgradeSnapshot) => { s.asset = '0xFF970A61A04b1cA14834A43f5de4533eBDDB5CC8'; }, // Bridged USDC.e
    (s: ArbitrumUpgradeSnapshot) => { s.asset = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'; }, // Base USDC
  ];
  for (const mutate of mutations) {
    const s = snapshot(); mutate(s);
    assert.throws(() => buildArbitrumUpgradePlan(s, candidates(), inputs()));
  }
});

test('preparation rejects broadcasting and mutating RPC at both RPC boundaries', async () => {
  const rpc = new ReadOnlyRpc('http://127.0.0.1:1', 42161, { staticNetwork: true });
  try {
    for (const method of ['eth_sendTransaction', 'eth_sendRawTransaction', 'eth_sign', 'personal_sign', 'anvil_setCode']) {
      await assert.rejects(rpc.send(method, []), /Preparation forbids/);
      await assert.rejects(rpc._send({ method, params: [], id: 1, jsonrpc: '2.0' }), /Preparation forbids/);
    }
  } finally { rpc.destroy(); }
});

test('CLI rejects execution flags before artifacts or RPC access', () => {
  const script = path.resolve(__dirname, '../../scripts/prepare-arbitrum-crosschain-upgrade.ts');
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

test('registry keeps the live five-provider manifest intact and expands only with actual adapter addresses', () => {
  const { fullNetworks, strategyProviders, providerLabels } = require('../../deploy/crosschain/registry');
  const fs = require('node:fs');
  const arb = fullNetworks().arbitrum;
  const base = fullNetworks().base;
  const manifest = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../deployments/arbitrum/crosschain.json'), 'utf8'));
  assert.deepEqual(strategyProviders(arb, manifest.contracts).map((p: any) => p.address), legacy.map(([p]) => p));
  assert.ok(!manifest.contracts.FluidProvider && !manifest.contracts.GauntletPrimeV2MorphoProvider);
  assert.equal(arb.strategy.fluidFToken, '0x1A996cb54bb95462040408C06122D45D6Cdb6096');
  assert.equal(arb.strategy.morphoV2Vault, '0x610D151aE40662AE148cdBaaE1Ea5904b6AFAE78');
  assert.notEqual(arb.strategy.fluidFToken, base.strategy.fluidFToken);
  assert.notEqual(arb.strategy.morphoV2Vault, base.strategy.morphoV2Vault);
  assert.ok(providerLabels(arb).includes('Fluid') && providerLabels(arb).includes('GauntletPrimeV2Morpho'));
  assert.deepEqual(strategyProviders(arb, { ...manifest.contracts,
    FluidProvider: a(31), GauntletPrimeV2MorphoProvider: a(32),
  }).map((p: any) => p.address), [...legacy.map(([p]) => p), a(31), a(32)]);
});
