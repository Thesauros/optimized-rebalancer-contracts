/** Read-only deployment preparation. This module never creates a signer. */
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  AbiCoder, Contract, ContractFactory, Interface, JsonRpcProvider, ZeroAddress,
  ZeroHash, formatEther, getAddress, getCreateAddress, keccak256, toQuantity, toUtf8Bytes,
  type JsonRpcPayload,
} from 'ethers';
import { chainConfigs } from '../utils/constants';

const ROOT = path.resolve(__dirname, '..');
const ARTIFACT = 'artifacts/contracts/providers/MorphoV2Provider.sol/MorphoV2Provider.json';
const READ_METHODS = new Set([
  'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getCode',
  'eth_getBalance', 'eth_getTransactionCount', 'eth_getStorageAt', 'eth_call',
  'eth_estimateGas', 'eth_gasPrice', 'eth_maxPriorityFeePerGas', 'eth_feeHistory',
]);

/** All RPC traffic passes this allowlist, including inherited provider methods. */
export class ReadOnlyRpc extends JsonRpcProvider {
  override async send(method: string, params: Array<any> | Record<string, any>): Promise<any> {
    if (!READ_METHODS.has(method)) throw new Error(`Preparation forbids RPC method ${method}`);
    return super.send(method, params);
  }

  override async _send(payload: JsonRpcPayload | JsonRpcPayload[]) {
    for (const request of Array.isArray(payload) ? payload : [payload]) {
      if (!READ_METHODS.has(request.method)) throw new Error(`Preparation forbids RPC method ${request.method}`);
    }
    return super._send(payload);
  }
}

const SOURCE_ABI = [
  'function asset() view returns(address)', 'function totalAssets() view returns(uint256)',
  'function accrueInterestView() view returns(uint256,uint256,uint256)',
  'function adaptersLength() view returns(uint256)', 'function adapters(uint256) view returns(address)',
  'function liquidityAdapter() view returns(address)', 'function liquidityData() view returns(bytes)',
  'function performanceFee() view returns(uint96)', 'function managementFee() view returns(uint96)',
  'function maxRate() view returns(uint64)',
  ...['canSendAssets', 'canReceiveShares', 'canSendShares', 'canReceiveAssets'].map((f) =>
    `function ${f}(address) view returns(bool)`),
];
const VAULT_ABI = [
  'function asset() view returns(address)', 'function getProviders() view returns(address[])',
  'function getEntryProvider() view returns(address)', 'function getTimelock() view returns(address)',
  'function getTreasury() view returns(address)', 'function hasRole(bytes32,address) view returns(bool)',
  'function setProviders(address[])', 'function setEntryProvider(address)',
];
const TIMELOCK_ABI = [
  'function owner() view returns(address)', 'function delay() view returns(uint256)',
  'function queue(address,uint256,string,bytes,uint256) returns(bytes32)',
  'function execute(address,uint256,string,bytes,uint256) payable returns(bytes)',
  'function cancel(address,uint256,string,bytes,uint256)',
];
const PROVIDER_ABI = [
  'function getIdentifier() view returns(string)',
  'function getSource(address,address,address) view returns(address)',
  'function getDepositRate(address) view returns(uint256)',
];

export type Target = { label: string; address: string; profile?: string };
type Artifact = { contractName: string; abi: any[]; bytecode: string; deployedBytecode: string };

export function appendProvider(current: string[], candidate: string): string[] {
  const normalized = current.map(getAddress);
  if (new Set(normalized.map((a) => a.toLowerCase())).size !== normalized.length) {
    throw new Error('Current provider list has duplicates; inspect before registration');
  }
  candidate = getAddress(candidate);
  return normalized.some((a) => a === candidate) ? normalized : [...normalized, candidate];
}

export function registrationProposal(vault: string, timelock: string, owner: string,
  current: string[], candidate: string, timestamp: number, delay: number) {
  const after = appendProvider(current, candidate);
  const signature = 'setProviders(address[])';
  const data = AbiCoder.defaultAbiCoder().encode(['address[]'], [after]);
  const eta = timestamp + delay + 3600;
  if (![timestamp, delay, eta].every(Number.isSafeInteger) || delay < 0) throw new Error('Invalid timelock timing');
  const args = [vault, 0, signature, data, eta];
  const iface = new Interface(TIMELOCK_ABI);
  return {
    status: 'UNSIGNED_DRAFT',
    before: current, after, signature, data, eta, etaUtc: new Date(eta * 1000).toISOString(),
    transactionId: keccak256(AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint256', 'string', 'bytes', 'uint256'], args)),
    registrationCall: { from: timelock, to: vault, value: '0x0',
      data: new Interface(VAULT_ABI).encodeFunctionData('setProviders', [after]) },
    queue: { from: owner, to: timelock, value: '0x0', data: iface.encodeFunctionData('queue', args) },
    execute: { from: owner, to: timelock, value: '0x0', data: iface.encodeFunctionData('execute', args) },
    cancel: { from: owner, to: timelock, value: '0x0', data: iface.encodeFunctionData('cancel', args) },
  };
}

function readJson(file: string): any { return JSON.parse(fs.readFileSync(file, 'utf8')); }
export function cleanError(error: unknown): string {
  const e = error as { shortMessage?: string; message?: string };
  return (e?.shortMessage ?? e?.message ?? String(error)).replace(/https?:\/\/[^\s"'<>]+/g, '[RPC URL]');
}

export function discoverTargets(network: string, root = ROOT): Target[] {
  const dir = path.join(root, 'deployments', network);
  const targets: Target[] = [];
  const main = path.join(dir, 'USDCRebalancerProxy.json');
  if (fs.existsSync(main)) targets.push({ label: 'main-usdc-vault', address: getAddress(readJson(main).address) });
  const manifestFile = path.join(dir, 'crosschain.json');
  if (fs.existsSync(manifestFile)) {
    const manifest = readJson(manifestFile);
    const address = manifest.contracts?.Strategy;
    if (address && !targets.some((t) => t.address.toLowerCase() === address.toLowerCase())) {
      targets.push({ label: 'crosschain-strategy', address: getAddress(address), profile: manifest.profile });
    }
  }
  return targets;
}

async function prepareTarget(rpc: ReadOnlyRpc, target: Target, source: Contract,
  asset: string, candidate: string, runtime: string | undefined, block: number, timestamp: number) {
  const vault = new Contract(target.address, VAULT_ABI, rpc);
  const at = { blockTag: block };
  const [vaultAsset, providers, entry, timelock, treasury] = await Promise.all([
    vault.asset(at), vault.getProviders(at), vault.getEntryProvider(at), vault.getTimelock(at), vault.getTreasury(at),
  ]);
  if (getAddress(vaultAsset) !== getAddress(asset)) throw new Error('Target vault asset mismatch');
  const current = Array.from(providers, (a) => getAddress(String(a)));
  if (!current.some((p) => p === getAddress(entry))) throw new Error('Current entry provider is not listed');
  const tl = new Contract(timelock, TIMELOCK_ABI, rpc);
  const [owner, delay, gates] = await Promise.all([
    tl.owner(at), tl.delay(at),
    Promise.all(['canSendAssets', 'canReceiveShares', 'canSendShares', 'canReceiveAssets'].map(async (f) =>
      [f, Boolean(await source[f](target.address, at))] as const)),
  ]);
  const proposal = registrationProposal(target.address, timelock, owner, current, candidate, timestamp, Number(delay));
  // eth_call state overrides exist only for this RPC evaluation; no code is deployed.
  const overrides = runtime ? [{ [candidate]: { code: runtime } }] : [];
  await rpc.send('eth_call', [proposal.registrationCall, toQuantity(block), ...overrides]);
  await rpc.send('eth_call', [proposal.queue, toQuantity(block)]);
  const provider = new Interface(PROVIDER_ABI);
  const rate = await rpc.send('eth_call', [
    { to: candidate, data: provider.encodeFunctionData('getDepositRate', [target.address]) },
    toQuantity(block), ...overrides,
  ]);
  return {
    ...target, asset: vaultAsset, currentEntryProvider: entry, treasury,
    timelock, timelockOwner: owner, timelockDelaySeconds: Number(delay),
    gates: Object.fromEntries(gates), gatesAllowed: gates.every(([, allowed]) => allowed),
    currentProviderCount: current.length, proposal,
    simulations: { appendProviders: runtime ? 'PASS_ETH_CALL_STATE_OVERRIDE' : 'PASS_ETH_CALL', queue: 'PASS_ETH_CALL',
      candidateAprRay: provider.decodeFunctionResult('getDepositRate', rate)[0].toString() },
    optionalEntrySelection: { requiredRole: 'ADMIN_ROLE', to: target.address, value: '0',
      data: new Interface(VAULT_ABI).encodeFunctionData('setEntryProvider', [candidate]),
      treasuryHasAdminRole: Boolean(await vault.hasRole(ZeroHash, treasury, at)),
      timelockOwnerHasAdminRole: Boolean(await vault.hasRole(ZeroHash, owner, at)),
      prerequisite: 'Provider must be deployed, verified and registered; explicit activation decision required' },
  };
}

export function assertRuntimeMatches(actual: string, expected: string): void {
  if (actual === '0x' || keccak256(actual) !== keccak256(expected)) {
    throw new Error('Existing provider runtime differs from the compiled candidate; refuse registration');
  }
}

export async function prepareNetwork(network: 'base' | 'mainnet', url: string, deployer: string,
  artifact: Artifact, providerAddress?: string) {
  const chainId = network === 'base' ? 8453 : 1;
  const config = chainConfigs[chainId];
  const strategy = config.morphoVaults.find((v) => v.version === 2);
  if (!strategy) throw new Error(`No V2 strategy configured on ${network}`);
  const rpc = new ReadOnlyRpc(url, chainId, { staticNetwork: true, batchMaxCount: 1 });
  const blockers: string[] = [];
  const warnings: string[] = [];
  try {
    if (BigInt(await rpc.send('eth_chainId', [])) !== BigInt(chainId)) throw new Error('RPC chain id mismatch');
    const block = await rpc.getBlock('latest');
    if (!block) throw new Error('Latest block unavailable');
    const sourceAddress = getAddress(strategy.vaultAddress);
    const at = { blockTag: block.number };
    const source = new Contract(sourceAddress, SOURCE_ABI, rpc);
    const sourceCode = await rpc.getCode(sourceAddress, block.number);
    if (sourceCode === '0x') throw new Error('Morpho source has no code');
    const sourceAsset = getAddress(await source.asset(at));
    if (sourceAsset !== getAddress(config.asset)) throw new Error('Morpho source asset mismatch');
    const [accrual, adapterCount, liquidityAdapter, liquidityData, performanceFee, managementFee, maxRate,
      balance, nonce, latestNonce, fees] = await Promise.all([
      source.accrueInterestView(at), source.adaptersLength(at), source.liquidityAdapter(at), source.liquidityData(at),
      source.performanceFee(at), source.managementFee(at), source.maxRate(at),
      rpc.getBalance(deployer, block.number), rpc.getTransactionCount(deployer, 'pending'),
      rpc.getTransactionCount(deployer, 'latest'), rpc.getFeeData(),
    ]);
    if (!providerAddress && nonce !== latestNonce) blockers.push('Deployer has pending transactions; refresh the nonce before deployment');
    const candidate = providerAddress ? getAddress(providerAddress) : getCreateAddress({ from: deployer, nonce });
    const candidateCode = await rpc.getCode(candidate, block.number);
    if (!providerAddress && candidateCode !== '0x') throw new Error('Predicted CREATE address already contains code');
    const creation = await new ContractFactory(artifact.abi, artifact.bytecode).getDeployTransaction(sourceAddress);
    if (typeof creation.data !== 'string') throw new Error('Missing constructor data');
    const runtime = await rpc.call({ from: deployer, data: creation.data, gasLimit: 10_000_000n, blockTag: block.number });
    if (runtime === '0x') throw new Error('Constructor simulation returned empty runtime');
    if (providerAddress) {
      assertRuntimeMatches(candidateCode, runtime);
      const existingProvider = new Contract(candidate, PROVIDER_ABI, rpc);
      if (getAddress(await existingProvider.getSource(sourceAsset, ZeroAddress, ZeroAddress, at)) !== sourceAddress ||
          await existingProvider.getIdentifier(at) !== 'Morpho_V2_Provider') {
        throw new Error('Existing provider source or identifier mismatch');
      }
    }
    const estimate = providerAddress ? 0n : await rpc.estimateGas({ from: deployer, data: creation.data, value: 0n });
    const gasLimit = (estimate * 125n + 99n) / 100n;
    const feePerGas = fees.maxFeePerGas ?? fees.gasPrice;
    if (feePerGas === null) throw new Error('RPC returned no gas fee estimate');
    const maxExecutionCostWei = gasLimit * feePerGas;
    if (balance < maxExecutionCostWei) blockers.push(`Funding shortfall: ${formatEther(maxExecutionCostWei - balance)} ETH`);
    if (!providerAddress && network === 'base') warnings.push('Base L1 data fees are additional; keep an ETH buffer and re-estimate before sending');
    warnings.push(providerAddress
      ? 'Registration drafts expire if provider lists, gates or timelock state change; refresh before queueing'
      : 'Predicted address and governance drafts are nonce-dependent; regenerate with --provider ACTUAL_ADDRESS after deployment');
    if (!process.env.ETHERSCAN_API_KEY) warnings.push('ETHERSCAN_API_KEY is missing for future verification');
    const existing = path.join(ROOT, 'deployments', network, `${strategy.strategy}MorphoProvider.json`);
    if (!providerAddress && fs.existsSync(existing)) blockers.push('A V2 deployment record already exists; reconcile it before creating another provider');
    const targets = [];
    for (const target of discoverTargets(network)) {
      try {
        const result = await prepareTarget(rpc, target, source, sourceAsset, candidate,
          providerAddress ? undefined : runtime, block.number, block.timestamp);
        if (!result.gatesAllowed) warnings.push(`${target.label}: Morpho gates do not allow every action`);
        targets.push(result);
      } catch (error) {
        targets.push({ ...target, error: cleanError(error) });
        warnings.push(`${target.label}: registration preparation incomplete; inspect target error`);
      }
    }
    const adapters = [];
    for (let i = 0; i < Number(adapterCount); ++i) {
      const address = await source.adapters(i, at);
      adapters.push({ address, codeHash: keccak256(await rpc.getCode(address, block.number)) });
    }
    return {
      network, chainId, status: blockers.length ? 'PREPARED_WITH_BLOCKERS'
        : providerAddress ? 'EXISTING_PROVIDER_VERIFIED' : 'PREPARED_NOT_DEPLOYED',
      deploymentReadyAtSnapshot: !providerAddress && blockers.length === 0,
      registrationPrepared: targets.length > 0 && targets.every((t) => !('error' in t) && t.gatesAllowed),
      snapshot: { block: block.number, hash: block.hash, timestamp: block.timestamp },
      deployer, nonce, latestNonce, candidateProvider: candidate,
      providerAddressKind: providerAddress ? 'VERIFIED_EXISTING' : 'PREDICTED_CREATE',
      predictedProvider: providerAddress ? null : candidate, deploymentRecord: `${strategy.strategy}MorphoProvider`,
      source: { address: sourceAddress, asset: sourceAsset, codeHash: keccak256(sourceCode),
        totalAssets: accrual[0].toString(), adapters, liquidityAdapter, liquidityData,
        performanceFee: performanceFee.toString(), managementFeePerSecond: managementFee.toString(), maxRate: maxRate.toString() },
      constructorArguments: [sourceAddress], creationCodeHash: keccak256(creation.data),
      expectedRuntimeCodeHash: keccak256(runtime),
      simulations: { constructor: 'PASS_ETH_CALL', estimatedGas: estimate.toString() },
      funding: { deploymentRequired: !providerAddress, deployerBalanceWei: balance.toString(), maxExecutionCostWei: maxExecutionCostWei.toString(),
        maxExecutionCostEth: formatEther(maxExecutionCostWei), includesBaseL1DataFee: false },
      unsignedDeployment: providerAddress ? null : {
        from: deployer, chainId, nonce, value: '0', data: creation.data, gasLimit: gasLimit.toString(),
        ...(fees.maxFeePerGas !== null && fees.maxPriorityFeePerGas !== null
          ? { type: 2, maxFeePerGas: fees.maxFeePerGas.toString(), maxPriorityFeePerGas: fees.maxPriorityFeePerGas.toString() }
          : { type: 0, gasPrice: feePerGas.toString() }),
      },
      verificationCommand: `FOUNDRY_AUTO_DETECT_REMAPPINGS=false npx hardhat verify --network ${network} --contract contracts/providers/MorphoV2Provider.sol:MorphoV2Provider <ACTUAL_DEPLOYED_ADDRESS> ${sourceAddress}`,
      targets, blockers, warnings,
    };
  } finally { rpc.destroy(); }
}

export function writeBundle(out: string, files: Record<string, unknown>): void {
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.mkdirSync(out); // Refuse to overwrite an existing preparation bundle.
  for (const [name, data] of Object.entries(files)) {
    if (path.basename(name) !== name) throw new Error('Bundle filename must not contain a path');
    fs.writeFileSync(path.join(out, name), JSON.stringify(data, null, 2) + '\n', { flag: 'wx' });
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.some((a) => !['--network', '--deployer', '--out', '--provider'].includes(a) && a.startsWith('--'))) {
    throw new Error('Only --network, --deployer, --out and --provider are supported; this tool cannot deploy');
  }
  const option = (key: string) => { const i = args.indexOf(key); return i < 0 ? undefined : args[i + 1]; };
  const network = option('--network') ?? 'all';
  if (!['base', 'mainnet', 'all'].includes(network)) throw new Error('Use --network base|mainnet|all');
  const providerAddress = option('--provider');
  if (providerAddress && network === 'all') throw new Error('--provider requires a single --network base|mainnet');
  const deployerInput = option('--deployer') ?? process.env.GAUNTLET_V2_DEPLOYER_ADDRESS;
  if (!deployerInput) throw new Error('Provide --deployer ADDRESS or GAUNTLET_V2_DEPLOYER_ADDRESS (public address only)');
  const deployer = getAddress(deployerInput);
  if (deployer === ZeroAddress) throw new Error('Deployer cannot be zero');
  const artifact = readJson(path.join(ROOT, ARTIFACT)) as Artifact;
  const debug = readJson(path.join(ROOT, ARTIFACT.replace(/\.json$/, '.dbg.json')));
  const build = readJson(path.resolve(path.dirname(path.join(ROOT, ARTIFACT)), debug.buildInfo));
  const networks = network === 'all' ? ['base', 'mainnet'] as const : [network as 'base' | 'mainnet'];
  const reports: Record<string, any> = {};
  for (const n of networks) {
    const url = process.env[n === 'base' ? 'BASE_RPC_URL' : 'ETHEREUM_RPC_URL'];
    try {
      if (!url) throw new Error(`Missing ${n === 'base' ? 'BASE_RPC_URL' : 'ETHEREUM_RPC_URL'}`);
      reports[n] = await prepareNetwork(n, url, deployer, artifact, providerAddress);
    } catch (error) { reports[n] = { network: n, status: 'BLOCKED', error: cleanError(error) }; }
    console.log(JSON.stringify({ network: n, status: reports[n].status,
      candidateProvider: reports[n].candidateProvider, blockers: reports[n].blockers, error: reports[n].error }));
  }
  const generatedAt = new Date().toISOString();
  const out = path.resolve(option('--out') ?? path.join(ROOT, 'deployments', 'plans', `gauntlet-v2-${generatedAt.replace(/[:.]/g, '-')}`));
  const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim();
  const dirty = Boolean(execFileSync('git', ['status', '--porcelain'], { cwd: ROOT, encoding: 'utf8' }).trim());
  writeBundle(out, {
    'manifest.json': { generatedAt, sourceCommit: commit, contract: artifact.contractName,
      workingTreeDirty: dirty, preparationScriptHash: keccak256(fs.readFileSync(__filename)),
      compiler: build.solcLongVersion, optimizer: build.input.settings.optimizer, evmVersion: build.input.settings.evmVersion,
      artifactCreationHash: keccak256(artifact.bytecode), standardInputHash: keccak256(toUtf8Bytes(JSON.stringify(build.input))),
      mode: 'READ_ONLY_NO_SIGNING_NO_BROADCAST', networks: Object.keys(reports),
      freshness: 'Refresh before deployment; after deployment regenerate each network with --provider ACTUAL_ADDRESS before registration' },
    'artifact.json': artifact, 'standard-json-input.json': build.input,
    ...Object.fromEntries(Object.entries(reports).map(([n, report]) => [`${n}.json`, report])),
  });
  console.log(`Prepared bundle: ${out}`);
  if (Object.values(reports).some((r) => r.error || r.blockers?.length)) process.exitCode = 2;
}

if (require.main === module) main().catch((error) => { console.error(cleanError(error)); process.exitCode = 1; });
