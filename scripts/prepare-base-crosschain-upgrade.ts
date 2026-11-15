/** Base-only, unsigned preparation. No signer or transaction submission exists here. */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  AbiCoder, Contract, ContractFactory, Interface, ZeroAddress, getAddress, keccak256,
  toQuantity, toUtf8Bytes,
} from 'ethers';
import { fullNetworks } from '../deploy/crosschain/registry';
import { ReadOnlyRpc, assertRuntimeMatches, cleanError, writeBundle } from './prepare-gauntlet-v2-deploy';

const ROOT = path.resolve(__dirname, '..');
export const BASE_STRATEGY = getAddress('0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33');
export const LEGACY_RUNTIME_HASH = '0x7afb3ac3455bd1a90c516a61e203e4db850eafc53c2213e294c4ea83ea46c5d3';
export const TARGET_RUNTIME_HASH = '0x6a9f9388ac5290c7a04b2415178eed2c197d1f11079913870b167765a229026b';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
const WAD = 10n ** 18n;
/** Reviewed legacy Base venues; an Aave registry retarget must be reviewed too. */
const LEGACY_SOURCES: Record<string, string> = {
  '0xddaa9700c0da1020ae5dabc7aa0a0bb750dd317c': '0xA238Dd80C259a72e81d7e4664a9801593F98d1c5',
  '0xa408a565a34b72fd6091f24b7ad4a15dcd29038a': '0xb125E6687d4313864e53df431d5425969c15Eb2F',
  '0x51b8bdcda5e41893737c9c3a08f528c97fcc1b8b': '0xc0c5689e6f4D256E861F65465b691aeEcC0dEb12',
  '0x9c35b8a92fc3a305712b9dd8a1c34310ea09c61c': '0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F',
  '0xddf2c1f8eaf567c084dee07658ed3906029395b1': '0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2',
};
const ADMIN_ABI = ['function owner() view returns(address)',
  'function UPGRADE_INTERFACE_VERSION() view returns(string)',
  'function upgradeAndCall(address,address,bytes) payable'];
const STRATEGY_ABI = [
  'function asset() view returns(address)', 'function getProviders() view returns(address[])',
  'function getEntryProvider() view returns(address)', 'function getTimelock() view returns(address)',
  'function getTreasury() view returns(address)', 'function getManagementFee() view returns(uint96)',
  'function getPerformanceFee() view returns(uint96)', 'function totalAssets() view returns(uint256)',
  'function totalSupply() view returns(uint256)', 'function providersHealthy() view returns(bool)',
  'function getProviderCap(address) view returns(uint256)',
  'function initializeSecurityAccounting(uint256)', 'function setProviders(address[])',
  'function setProviderCap(address,uint256)',
];
const PROVIDER_ABI = ['function getSource(address,address,address) view returns(address)',
  'function getDepositBalance(address,address) view returns(uint256)',
  'function getIdentifier() view returns(string)'];
const TIMELOCK_ABI = ['function owner() view returns(address)', 'function delay() view returns(uint256)',
  'function queue(address,uint256,string,bytes,uint256) returns(bytes32)',
  'function execute(address,uint256,string,bytes,uint256) payable returns(bytes)',
  'function cancel(address,uint256,string,bytes,uint256)'];

type ProviderState = { address: string; source: string; runtimeHash: string; sourceRuntimeHash: string;
  identifier: string; assets: string; capBps: number };
export type BaseUpgradeSnapshot = {
  chainId: number; block: number; blockHash: string; timestamp: number;
  profile: string; proxy: string; implementation: string; implementationRuntimeHash: string;
  manifestImplementation: string; manifestRuntimeHash: string; proxyAdmin: string; proxyAdminOwner: string;
  adminInterfaceVersion: string; timelock: string; timelockOwner: string; delay: number;
  asset: string; treasury: string; managementFee: string; performanceFee: string;
  totalAssets: string; totalSupply: string; healthy: boolean; entryProvider: string; providers: ProviderState[];
};
export type UpgradeCandidate = { name: string; address?: string; source?: string;
  expectedRuntimeHash: string; runtimeVerified: boolean; sourceVerified: boolean;
  unsignedDeployment: { chainId: number; value: string; data: string }; estimatedDeploymentGas?: string };
export type BaseUpgradeInputs = {
  historicalHwm?: string; attestHistoricalHwm: boolean; attestProviderSources: boolean;
  hwmEvidence?: string; providerSourcesEvidence?: string;
  acceptLegacyFeeWaiver: boolean; fluidCapBps?: number; morphoV2CapBps?: number;
};

function address(value: string): string {
  const result = getAddress(value);
  if (result === ZeroAddress) throw new Error('Zero address is not a release target');
  return result;
}
function decimal(value: string, label: string): bigint {
  if (!/^\d+$/.test(value)) throw new Error(`${label} must be an unsigned decimal integer`);
  return BigInt(value);
}
export function ceilingPps(assets: string, supply: string): bigint {
  const a = decimal(assets, 'totalAssets');
  const s = decimal(supply, 'totalSupply');
  if (s === 0n) throw new Error('Zero Strategy supply cannot be migrated');
  return (a * WAD + s - 1n) / s;
}

/** Pure plan builder: incomplete release inputs never produce executable calldata. */
export function buildBaseUpgradePlan(snapshot: BaseUpgradeSnapshot, candidates: UpgradeCandidate[], inputs: BaseUpgradeInputs) {
  if (snapshot.chainId !== 8453) throw new Error('Only Base chain 8453 is supported');
  if (!['stand', 'production'].includes(snapshot.profile)) throw new Error('Unexpected manifest profile');
  if (address(snapshot.proxy) !== BASE_STRATEGY) throw new Error('Unexpected Base cross-chain Strategy proxy');
  if (address(snapshot.implementation) !== address(snapshot.manifestImplementation) ||
      snapshot.implementationRuntimeHash !== snapshot.manifestRuntimeHash ||
      snapshot.implementationRuntimeHash !== LEGACY_RUNTIME_HASH) throw new Error('Legacy implementation/runtime drift');
  if (snapshot.adminInterfaceVersion !== '5.0.0') throw new Error('Expected OZ 5 ProxyAdmin');
  for (const key of ['proxyAdmin', 'proxyAdminOwner', 'timelock', 'timelockOwner', 'asset', 'treasury'] as const) address(snapshot[key]);
  if (!Number.isSafeInteger(snapshot.timestamp) || !Number.isSafeInteger(snapshot.delay) || snapshot.delay < 1800) {
    throw new Error('Invalid snapshot timestamp or Timelock delay');
  }
  if (!snapshot.healthy) throw new Error('Unhealthy current providers cannot be migrated');
  const providers = snapshot.providers.map((p) => ({ ...p, address: address(p.address), source: address(p.source) }));
  if (!providers.length || new Set(providers.map((p) => p.address)).size !== providers.length ||
      new Set(providers.map((p) => p.source)).size !== providers.length) throw new Error('Duplicate/empty current provider sources');
  const entry = providers.find((p) => p.address === address(snapshot.entryProvider));
  if (!entry || entry.capBps !== 0) throw new Error('Current entry must remain listed and uncapped');
  const pps = ceilingPps(snapshot.totalAssets, snapshot.totalSupply);
  const blockers: string[] = [];
  let historicalHwm: bigint | undefined;
  if (!inputs.historicalHwm) blockers.push('Governance-attested historical HWM is missing');
  else {
    historicalHwm = decimal(inputs.historicalHwm, 'historicalHwm');
    if (historicalHwm === 0n || historicalHwm < pps) throw new Error('Historical HWM must be positive and at least fresh ceiling PPS');
  }
  if (!inputs.attestHistoricalHwm) blockers.push('Historical HWM provenance is not attested');
  if (!inputs.attestProviderSources) blockers.push('Current provider source provenance is not attested');
  if (!inputs.hwmEvidence?.trim()) blockers.push('Historical HWM evidence reference is missing');
  if (!inputs.providerSourcesEvidence?.trim()) blockers.push('Provider source evidence reference is missing');
  if (!inputs.acceptLegacyFeeWaiver) blockers.push('Governance acceptance of unsettled legacy fee waiver is missing');
  const names = ['Rebalancer', 'FluidProvider', 'MorphoV2Provider'];
  if (candidates.length !== names.length || names.some((n) => candidates.filter((c) => c.name === n).length !== 1)) {
    throw new Error('Require exactly Rebalancer, FluidProvider and MorphoV2Provider candidates');
  }
  const ordered = names.map((n) => candidates.find((c) => c.name === n)!);
  const base = fullNetworks().base;
  const expectedSources: Record<string, string | undefined> = {
    FluidProvider: base.strategy.fluidFToken, MorphoV2Provider: base.strategy.morphoV2Vault,
  };
  for (const c of ordered) {
    if (!c.address) blockers.push(`${c.name} actual deployed address is missing; constructor plan only`);
    else address(c.address);
    if (!c.runtimeVerified || !c.sourceVerified) blockers.push(`${c.name} runtime/source verification is incomplete`);
    if (c.unsignedDeployment.chainId !== 8453) throw new Error('Candidate deployment must be Base only');
    if (!/^0x[0-9a-f]{64}$/i.test(c.expectedRuntimeHash)) throw new Error('Candidate runtime hash is invalid');
    if (c.name !== 'Rebalancer' && !c.source) throw new Error('New provider source is missing');
    if (c.name === 'Rebalancer' && c.expectedRuntimeHash !== TARGET_RUNTIME_HASH) throw new Error('Target Rebalancer runtime differs from the reviewed main build');
    if (c.name !== 'Rebalancer' && (!expectedSources[c.name] || address(c.source!) !== address(expectedSources[c.name]!))) {
      throw new Error('New provider source differs from the Base registry');
    }
  }
  const additions = ordered.slice(1);
  const allAddresses = [...providers.map((p) => p.address), ...additions.filter((c) => c.address).map((c) => address(c.address!))];
  const allSources = [...providers.map((p) => p.source), ...additions.filter((c) => c.source).map((c) => address(c.source!))];
  if (new Set(allAddresses).size !== allAddresses.length || new Set(allSources).size !== allSources.length) {
    throw new Error('New venues must have distinct provider addresses and sources');
  }
  const caps = [inputs.fluidCapBps, inputs.morphoV2CapBps];
  caps.forEach((cap, i) => {
    if (cap === undefined) blockers.push(`${additions[i].name} explicit reviewed cap is missing`);
    else if (!Number.isSafeInteger(cap) || cap <= 0 || cap > 10_000) throw new Error('New venue caps must be 1..10000 bps');
    else if (cap !== base.strategy.capsBps[i === 0 ? 'Fluid' : 'GauntletPrimeV2Morpho']) {
      throw new Error('New venue cap differs from the Base registry; review and update configuration first');
    }
  });
  const eta = snapshot.timestamp + snapshot.delay + 3600;
  if (!Number.isSafeInteger(eta)) throw new Error('Invalid Timelock ETA');
  const timelock = new Interface(TIMELOCK_ABI);
  const strategy = new Interface(STRATEGY_ABI);
  const delayed = (signature: string, data: string) => {
    const args = [snapshot.proxy, 0, signature, data, eta];
    return { signature, data, eta,
      transactionId: keccak256(AbiCoder.defaultAbiCoder().encode(['address', 'uint256', 'string', 'bytes', 'uint256'], args)),
      queue: { from: snapshot.timelockOwner, to: snapshot.timelock, value: '0', data: timelock.encodeFunctionData('queue', args) },
      execute: { from: snapshot.timelockOwner, to: snapshot.timelock, value: '0', data: timelock.encodeFunctionData('execute', args) },
      cancel: { from: snapshot.timelockOwner, to: snapshot.timelock, value: '0', data: timelock.encodeFunctionData('cancel', args) } };
  };
  const ready = blockers.length === 0;
  return {
    status: ready ? 'UNSIGNED_READY_FOR_FORK_AND_HUMAN_REVIEW' : 'DRAFT_NOT_SIGNABLE',
    mode: 'READ_ONLY_NO_SIGNING_NO_BROADCAST', chainId: 8453, snapshot, candidates: ordered, inputs,
    minimumHwmAtSnapshot: pps.toString(), blockers,
    preserve: { proxy: snapshot.proxy, entryProvider: snapshot.entryProvider, providers,
      feeTreatment: 'Unsettled legacy fees waived; assets and timestamp baseline reset during migration' },
    nextProviders: ready ? allAddresses : null,
    atomicUpgrade: ready ? { from: snapshot.proxyAdminOwner, to: snapshot.proxyAdmin, value: '0',
      data: new Interface(ADMIN_ABI).encodeFunctionData('upgradeAndCall', [snapshot.proxy, ordered[0].address,
        strategy.encodeFunctionData('initializeSecurityAccounting', [historicalHwm])]) } : null,
    governance: ready ? [
      delayed('setProviders(address[])', AbiCoder.defaultAbiCoder().encode(['address[]'], [allAddresses])),
      ...additions.map((c, i) => delayed('setProviderCap(address,uint256)',
        AbiCoder.defaultAbiCoder().encode(['address', 'uint256'], [c.address, caps[i]]))),
    ] : [],
    executionOrder: ['Deploy and verify candidates; regenerate with actual addresses',
      'Freeze operational changes and refresh HWM/source evidence at a canonical block',
      'Review and send atomic ProxyAdmin upgrade with security accounting initialization',
      'Queue provider registration and caps; wait actual Timelock delay',
      'Execute registration followed by both caps before allocating into either new venue',
      'Update manifests/codehashes and compatible ops release; verify fresh complete NAV and exits'],
    postconditions: ['Existing proxy identities, providers/order, entry, caps, fees, treasury, roles and holdings preserved',
      'HWM initialized to attested value; current provider sources pinned; healthy complete NAV',
      'Two distinct appended providers pinned to verified sources and explicit caps',
      'No allocation to new venues before registration, caps and valuation checks pass'],
    freshness: 'Refresh before signing; HWM must still cover ceiling PPS at execution. Snapshot, calldata and ETA are not permanent authorization.',
    rollback: 'Do not blindly restore legacy bytecode after initializing security state or funding new venues; rehearse unwind against the actual post-upgrade state.',
  };
}

type Artifact = { contractName: string; abi: any[]; bytecode: string; deployedBytecode: string };
export function assertArtifactCoherence(artifact: Artifact, compiled: any): void {
  if (!compiled || artifact.bytecode !== '0x' + compiled.evm?.bytecode?.object ||
      artifact.deployedBytecode !== '0x' + compiled.evm?.deployedBytecode?.object ||
      JSON.stringify(artifact.abi) !== JSON.stringify(compiled.abi)) {
    throw new Error('Artifact ABI/bytecode differs from its compiler build output');
  }
}
function loadArtifact(name: string) {
  const subdir = name === 'Rebalancer' ? '' : 'providers/';
  const file = path.join(ROOT, `artifacts/contracts/${subdir}${name}.sol/${name}.json`);
  const artifact = JSON.parse(fs.readFileSync(file, 'utf8')) as Artifact;
  const debug = JSON.parse(fs.readFileSync(file.replace(/\.json$/, '.dbg.json'), 'utf8'));
  const build = JSON.parse(fs.readFileSync(path.resolve(path.dirname(file), debug.buildInfo), 'utf8'));
  if (artifact.contractName !== name) throw new Error('Artifact contract name mismatch');
  assertArtifactCoherence(artifact, build.output.contracts[`contracts/${subdir}${name}.sol`]?.[name]);
  if (build.solcVersion !== '0.8.33' || !build.input.settings.optimizer?.enabled ||
      build.input.settings.optimizer.runs !== 200 || build.input.settings.evmVersion !== 'paris') {
    throw new Error('Compile with pinned Solidity 0.8.33, optimizer 200 and EVM Paris');
  }
  const lock = JSON.parse(fs.readFileSync(path.join(ROOT, 'package-lock.json'), 'utf8'));
  for (const pkg of ['@openzeppelin/contracts', '@openzeppelin/contracts-upgradeable']) {
    const installed = JSON.parse(fs.readFileSync(path.join(ROOT, 'node_modules', pkg, 'package.json'), 'utf8'));
    if (installed.version !== '5.4.0' || lock.packages['node_modules/' + pkg]?.version !== '5.4.0') {
      throw new Error('Pinned OpenZeppelin 5.4.0 dependencies are required');
    }
  }
  for (const [source, record] of Object.entries(build.input.sources) as [string, { content: string }][]) {
    const candidates = [path.join(ROOT, source), path.join(ROOT, 'node_modules', source),
      ...(source.startsWith('morpho-blue/') ? [path.join(ROOT, 'lib/morpho-blue/src', source.slice('morpho-blue/'.length))] : [])];
    const file = candidates.find((candidate) => fs.existsSync(candidate));
    if (!file || fs.readFileSync(file, 'utf8') !== record.content) {
      throw new Error(`Stale build input: ${source}`);
    }
  }
  return { artifact, provenance: { compiler: build.solcLongVersion, optimizer: build.input.settings.optimizer,
    standardInputHash: keccak256(toUtf8Bytes(JSON.stringify(build.input))), creationHash: keccak256(artifact.bytecode) } };
}

export async function prepareBaseUpgrade(url: string, inputs: BaseUpgradeInputs,
  deployed: { implementation?: string; fluidProvider?: string; morphoV2Provider?: string } = {}) {
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments/base/crosschain.json'), 'utf8'));
  if (manifest.network !== 'base' || String(manifest.chainId) !== '8453' || manifest.role !== 'hub') throw new Error('Unexpected Base manifest');
  const rpc = new ReadOnlyRpc(url, 8453, { staticNetwork: true, batchMaxCount: 1, cacheTimeout: -1 });
  try {
    if (BigInt(await rpc.send('eth_chainId', [])) !== 8453n) throw new Error('Only Base chain 8453 is supported');
    const block = await rpc.getBlock('latest');
    if (!block?.hash) throw new Error('Canonical snapshot block unavailable');
    const at = { blockTag: block.number };
    const proxy = address(manifest.contracts.Strategy);
    if (proxy !== BASE_STRATEGY) throw new Error('Unexpected Base cross-chain Strategy proxy');
    const slot = async (key: string) => address('0x' + (await rpc.getStorage(proxy, key, block.number)).slice(-40));
    const [implementation, proxyAdmin] = await Promise.all([slot(IMPL_SLOT), slot(ADMIN_SLOT)]);
    const admin = new Contract(proxyAdmin, ADMIN_ABI, rpc);
    const strategy = new Contract(proxy, STRATEGY_ABI, rpc);
    const [proxyAdminOwner, adminInterfaceVersion, asset, rawProviders, entryProvider, timelock, treasury,
      managementFee, performanceFee, totalAssets, totalSupply, healthy, legacyCode] = await Promise.all([
      admin.owner(at), admin.UPGRADE_INTERFACE_VERSION(at), strategy.asset(at), strategy.getProviders(at),
      strategy.getEntryProvider(at), strategy.getTimelock(at), strategy.getTreasury(at),
      strategy.getManagementFee(at), strategy.getPerformanceFee(at), strategy.totalAssets(at),
      strategy.totalSupply(at), strategy.providersHealthy(at), rpc.getCode(implementation, block.number),
    ]);
    if (address(timelock) !== address(manifest.contracts.Timelock)) throw new Error('Manifest Timelock drift');
    const base = fullNetworks().base;
    if (address(asset) !== address(base.usdc)) throw new Error('Base USDC asset mismatch');
    const tl = new Contract(timelock, TIMELOCK_ABI, rpc);
    const [timelockOwner, delay] = await Promise.all([tl.owner(at), tl.delay(at)]);
    const providers: ProviderState[] = await Promise.all(Array.from(rawProviders, String).map(async (provider) => {
      const p = new Contract(provider, PROVIDER_ABI, rpc);
      const [source, identifier, assets, capBps, code] = await Promise.all([
        p.getSource(asset, proxy, ZeroAddress, at), p.getIdentifier(at), p.getDepositBalance(proxy, proxy, at),
        strategy.getProviderCap(provider, at), rpc.getCode(provider, block.number),
      ]);
      const sourceCode = await rpc.getCode(source, block.number);
      if (code === '0x' || sourceCode === '0x') throw new Error('Current provider/source has no code');
      return { address: address(provider), source: address(source), identifier, assets: String(assets),
        capBps: Number(capBps), runtimeHash: keccak256(code), sourceRuntimeHash: keccak256(sourceCode) };
    }));
    const [first, ...rest] = base.strategy.reusedProviders;
    const expectedLegacy = [first.address, manifest.contracts.CompoundV3Provider, ...rest.map((p) => p.address)].map(address);
    if (providers.length !== expectedLegacy.length || providers.some((p, i) => p.address !== expectedLegacy[i]) ||
        address(entryProvider) !== expectedLegacy[0]) throw new Error('Current legacy provider order/count/entry differs from the Base registry');
    for (const expected of base.strategy.reusedProviders) {
      if (!providers.some((p) => p.address === address(expected.address))) throw new Error(`Missing preserved provider ${expected.label}`);
    }
    const labels = [first.label, 'CompoundV3', ...rest.map((p) => p.label)];
    providers.forEach((p, i) => {
      if (p.capBps !== (base.strategy.capsBps[labels[i]] ?? 0)) throw new Error(`Current cap differs from the Base registry: ${labels[i]}`);
      const expectedSource = LEGACY_SOURCES[p.address.toLowerCase()];
      if (!expectedSource || p.source !== address(expectedSource)) throw new Error(`Current source differs from the reviewed legacy venue: ${labels[i]}`);
    });
    const compound = providers[1];
    if (!base.strategy.comet || compound.source !== address(base.strategy.comet)) throw new Error('Current Compound source differs from the Base registry');
    const snapshot: BaseUpgradeSnapshot = { chainId: 8453, block: block.number, blockHash: block.hash,
      timestamp: block.timestamp, profile: manifest.profile, proxy, implementation,
      implementationRuntimeHash: keccak256(legacyCode), manifestImplementation: manifest.contracts.StrategyImplementation,
      manifestRuntimeHash: manifest.codehashes.StrategyImplementation, proxyAdmin, proxyAdminOwner,
      adminInterfaceVersion, timelock, timelockOwner, delay: Number(delay), asset, treasury,
      managementFee: String(managementFee), performanceFee: String(performanceFee), totalAssets: String(totalAssets),
      totalSupply: String(totalSupply), healthy, entryProvider, providers };
    const preservedContracts: Record<string, { proxy: string; implementation: string; runtimeHash: string }> = {};
    for (const name of ['EpochVault', 'TickAccountant', 'ChainAgent']) {
      const relatedProxy = address(manifest.contracts[name]);
      const liveImpl = address('0x' + (await rpc.getStorage(relatedProxy, IMPL_SLOT, block.number)).slice(-40));
      const runtimeHash = keccak256(await rpc.getCode(liveImpl, block.number));
      if (liveImpl !== address(manifest.contracts[name + 'Implementation']) || runtimeHash !== manifest.codehashes[name + 'Implementation']) {
        throw new Error(`${name} deployment drift`);
      }
      preservedContracts[name] = { proxy: relatedProxy, implementation: liveImpl, runtimeHash };
    }
    const config = base.strategy as typeof base.strategy & { morphoV2Vault?: string };
    if (!config.fluidFToken || !config.morphoV2Vault) throw new Error('Both Base venue sources must be configured');
    const definitions = [
      { name: 'Rebalancer', deployed: deployed.implementation, source: undefined },
      { name: 'FluidProvider', deployed: deployed.fluidProvider, source: config.fluidFToken },
      { name: 'MorphoV2Provider', deployed: deployed.morphoV2Provider, source: config.morphoV2Vault },
    ];
    const artifacts = [];
    const candidates: UpgradeCandidate[] = [];
    for (const definition of definitions) {
      const { artifact, provenance } = loadArtifact(definition.name);
      const constructor = await new ContractFactory(artifact.abi, artifact.bytecode).getDeployTransaction(...(definition.source ? [definition.source] : []));
      const creation = String(constructor.data);
      const runtime = await rpc.send('eth_call', [{ data: creation, gas: '0x1312d00' }, toQuantity(block.number)]);
      if (runtime === '0x') throw new Error(`${definition.name} constructor simulation returned empty code`);
      let sourceVerified = true;
      if (definition.source) {
        const source = new Contract(definition.source, ['function asset() view returns(address)',
          ...['canSendAssets', 'canReceiveShares', 'canSendShares', 'canReceiveAssets'].map((f) => `function ${f}(address) view returns(bool)`)], rpc);
        if (address(await source.asset(at)) !== address(asset)) throw new Error(`${definition.name} source asset mismatch`);
        if (definition.name === 'MorphoV2Provider') {
          sourceVerified = (await Promise.all(['canSendAssets', 'canReceiveShares', 'canSendShares', 'canReceiveAssets']
            .map((f) => source[f](proxy, at)))).every(Boolean);
        }
      }
      if (definition.deployed) {
        assertRuntimeMatches(await rpc.getCode(address(definition.deployed), block.number), runtime);
        if (definition.source) {
          const actual = new Contract(definition.deployed, PROVIDER_ABI, rpc);
          if (address(await actual.getSource(asset, proxy, ZeroAddress, at)) !== address(definition.source)) throw new Error('Candidate immutable source mismatch');
        }
      }
      const gas = await rpc.send('eth_estimateGas', [{ data: creation, value: '0x0' }, toQuantity(block.number)]);
      candidates.push({ name: definition.name, address: definition.deployed && address(definition.deployed), source: definition.source,
        expectedRuntimeHash: keccak256(runtime), runtimeVerified: Boolean(definition.deployed), sourceVerified,
        unsignedDeployment: { chainId: 8453, value: '0', data: creation }, estimatedDeploymentGas: BigInt(gas).toString() });
      artifacts.push({ name: definition.name, ...provenance });
    }
    const plan = buildBaseUpgradePlan(snapshot, candidates, inputs);
    let atomicUpgradeGas: string | null = null;
    if (plan.atomicUpgrade) {
      const tx = { ...plan.atomicUpgrade, value: '0x0' };
      await rpc.send('eth_call', [tx, toQuantity(block.number)]);
      atomicUpgradeGas = BigInt(await rpc.send('eth_estimateGas', [tx, toQuantity(block.number)])).toString();
      for (const call of plan.governance) await rpc.send('eth_call', [{ ...call.queue, value: '0x0' }, toQuantity(block.number)]);
    }
    if ((await rpc.getBlock(block.number))?.hash !== block.hash) throw new Error('Snapshot block reorged; refresh preparation');
    return { ...plan, preservedContracts, artifacts, estimates: { atomicUpgradeGas,
      caveat: 'Gas estimates are snapshot-specific and exclude Base L1 data fees; registration/execution requires the staged fork rehearsal' } };
  } finally { rpc.destroy(); }
}

async function main() {
  const args = process.argv.slice(2);
  const values = ['--historical-hwm', '--implementation', '--fluid-provider', '--morpho-v2-provider',
    '--fluid-cap-bps', '--morpho-v2-cap-bps', '--hwm-evidence', '--sources-evidence', '--out'];
  const flags = ['--attest-historical-hwm', '--attest-provider-sources', '--accept-legacy-fee-waiver'];
  for (let i = 0; i < args.length; ++i) {
    if (flags.includes(args[i])) continue;
    if (!values.includes(args[i]) || !args[i + 1] || args[i + 1].startsWith('--')) {
      throw new Error('Only documented Base preparation flags are supported; this tool cannot deploy, sign or send');
    }
    ++i;
  }
  const option = (key: string) => { const index = args.indexOf(key); return index < 0 ? undefined : args[index + 1]; };
  const cap = (key: string) => option(key) === undefined ? undefined : Number(option(key));
  if (!process.env.BASE_RPC_URL) throw new Error('BASE_RPC_URL is required');
  const plan = await prepareBaseUpgrade(process.env.BASE_RPC_URL, {
    historicalHwm: option('--historical-hwm'), attestHistoricalHwm: args.includes('--attest-historical-hwm'),
    attestProviderSources: args.includes('--attest-provider-sources'), acceptLegacyFeeWaiver: args.includes('--accept-legacy-fee-waiver'),
    hwmEvidence: option('--hwm-evidence'), providerSourcesEvidence: option('--sources-evidence'),
    fluidCapBps: cap('--fluid-cap-bps'), morphoV2CapBps: cap('--morpho-v2-cap-bps'),
  }, { implementation: option('--implementation'), fluidProvider: option('--fluid-provider'), morphoV2Provider: option('--morpho-v2-provider') });
  const out = path.resolve(option('--out') ?? path.join(ROOT, 'deployments/plans', `base-crosschain-upgrade-${new Date().toISOString().replace(/[:.]/g, '-')}`));
  writeBundle(out, { 'base-upgrade.json': plan, 'manifest.json': {
    change: 'base-crosschain-upgrade', generatedAt: new Date().toISOString(),
    sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim(),
    workingTreeDirty: Boolean(execFileSync('git', ['status', '--porcelain'], { cwd: ROOT, encoding: 'utf8' }).trim()),
    preparationScriptHash: keccak256(fs.readFileSync(__filename)), mode: plan.mode, chainId: 8453,
  } });
  console.log(JSON.stringify({ status: plan.status, out, blockers: plan.blockers }));
  if (plan.blockers.length) process.exitCode = 2;
}

if (require.main === module) main().catch((error) => { console.error(cleanError(error)); process.exitCode = 1; });
