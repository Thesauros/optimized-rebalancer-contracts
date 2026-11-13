/**
 * Executes the three Base governance operations queued on 2026-11-13, in the
 * reviewed order, once the Timelock delay has elapsed:
 *   1. setProviders(address[]) registering Fluid and GauntletPrimeV2Morpho,
 *   2. setProviderCap(Fluid, 3000),
 *   3. setProviderCap(GauntletPrimeV2Morpho, 2000).
 *
 * Every call broadcasts the exact calldata recorded in the plan bundle. The
 * executor must be quiescent until all three succeed; the script runs them back
 * to back and asserts the full post-state before writing evidence and updating
 * the Base manifest with the two newly registered providers.
 */
import fs from 'node:fs';
import path from 'node:path';
import { JsonRpcProvider, Wallet, Contract, keccak256, getAddress, ZeroAddress } from 'ethers';

const ROOT = path.resolve(__dirname, '..');
const PLAN_PATH = path.join(ROOT, 'changes/base-crosschain-upgrade/base-upgrade-plan.json');
const DEPLOYED_PATH = path.join(ROOT, 'changes/base-crosschain-upgrade/base-candidate-deployment.json');
const OUT = path.join(ROOT, 'changes/base-crosschain-upgrade/base-governance-execution.json');
const MANIFEST = path.join(ROOT, 'deployments/base/crosschain.json');
const RPC = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ADMIN_ROLE = ZeroAddress.padEnd(66, '0');
const MAX_ASSET_DRIFT_PPM = 1000n;

const STRATEGY_ABI = [
  'function asset() view returns (address)',
  'function getProviders() view returns (address[])',
  'function getEntryProvider() view returns (address)',
  'function getTimelock() view returns (address)',
  'function getTreasury() view returns (address)',
  'function getManagementFee() view returns (uint96)',
  'function getPerformanceFee() view returns (uint96)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function providersHealthy() view returns (bool)',
  'function getProviderCap(address) view returns (uint256)',
  'function getHighWaterMark() view returns (uint256)',
  'function getPinnedProviderSource(address) view returns (address)',
  'function getLastTotalAssets() view returns (uint256)',
  'function getLastTimestamp() view returns (uint64)',
  'function hasRole(bytes32,address) view returns (bool)',
];
const TIMELOCK_ABI = [
  'function owner() view returns (address)',
  'function delay() view returns (uint256)',
  'function queued(bytes32) view returns (bool)',
];
const PROVIDER_ABI = ['function getSource(address,address,address) view returns (address)', 'function getIdentifier() view returns (string)'];

const report: string[] = [];
function eq(label: string, actual: unknown, expected: unknown) {
  if (String(actual).toLowerCase() !== String(expected).toLowerCase()) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
  report.push(`${label} = ${actual}`);
}
function ok(label: string, value: unknown) { report.push(`${label} = ${value}`); }

async function main() {
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key) throw new Error('DEPLOYER_PRIVATE_KEY is required');
  const plan = JSON.parse(fs.readFileSync(PLAN_PATH, 'utf8'));
  const deployed = JSON.parse(fs.readFileSync(DEPLOYED_PATH, 'utf8')).contracts;
  const rpc = new JsonRpcProvider(RPC, 8453, { staticNetwork: true, batchMaxCount: 1 });
  const wallet = new Wallet(key, rpc);
  const deployer = wallet.address;
  const strategy = new Contract(plan.snapshot.proxy, STRATEGY_ABI, rpc);
  const timelock = new Contract(plan.snapshot.timelock, TIMELOCK_ABI, rpc);
  const fluid = plan.candidates.find((c: any) => c.name === 'FluidProvider');
  const morpho = plan.candidates.find((c: any) => c.name === 'MorphoV2Provider');
  const implementation = plan.candidates.find((c: any) => c.name === 'Rebalancer').address;

  // ---- readiness ---------------------------------------------------------
  eq('timelock.owner', await timelock.owner(), deployer);
  eq('proxy implementation', getAddress('0x' + (await rpc.getStorage(plan.snapshot.proxy, IMPL_SLOT)).slice(-40)), implementation);
  const supplyBefore = BigInt(await strategy.totalSupply());
  const assetsBefore = BigInt(await strategy.totalAssets());
  eq('providers before registration', (await strategy.getProviders()).length, plan.preserve.providers.length);
  for (const operation of plan.governance) {
    if (!(await timelock.queued(operation.transactionId))) throw new Error(`${operation.signature} is no longer queued`);
  }
  ok('all three operations queued', plan.governance.map((g: any) => g.signature).join(' | '));

  // ---- execute in the reviewed order -------------------------------------
  const executed: any[] = [];
  for (const operation of plan.governance) {
    const latest = await rpc.getBlock('latest');
    if (!latest) throw new Error('No latest block');
    if (latest.timestamp < operation.eta) {
      throw new Error(`${operation.signature} unlocks at ${new Date(operation.eta * 1000).toISOString()}, chain is at ${new Date(latest.timestamp * 1000).toISOString()}`);
    }
    const simulated = await rpc.call({ from: deployer, to: operation.execute.to, data: operation.execute.data, value: BigInt(operation.execute.value) });
    ok(`${operation.signature} simulation`, `ok (return ${simulated})`);
    const tx = await wallet.sendTransaction({
      to: operation.execute.to, data: operation.execute.data,
      value: BigInt(operation.execute.value), chainId: 8453,
    });
    const receipt = await tx.wait(2);
    if (!receipt || receipt.status !== 1) throw new Error(`${operation.signature} execution reverted`);
    if (await timelock.queued(operation.transactionId)) throw new Error(`${operation.signature} is still marked queued after execution`);
    executed.push({
      signature: operation.signature, transactionId: operation.transactionId, eta: operation.eta,
      txHash: receipt.hash, blockNumber: receipt.blockNumber, gasUsed: receipt.gasUsed.toString(),
      calldata: operation.execute.data,
    });
    ok(`executed ${operation.signature}`, `${receipt.hash} block ${receipt.blockNumber} gas ${receipt.gasUsed}`);
  }

  // ---- post-conditions ---------------------------------------------------
  const lastBlock = executed[executed.length - 1].blockNumber;
  const at = { blockTag: lastBlock };
  const providers = (await strategy.getProviders(at)).map(getAddress);
  eq('provider count', providers.length, plan.nextProviders.length);
  providers.forEach((p: string, i: number) => eq(`provider[${i}]`, p, plan.nextProviders[i]));
  eq('entry provider', getAddress(await strategy.getEntryProvider(at)), plan.preserve.entryProvider);
  for (const expected of plan.preserve.providers) {
    eq(`cap ${expected.identifier} ${expected.address.slice(0, 8)}`, await strategy.getProviderCap(expected.address, at), expected.capBps);
    eq(`pinned source ${expected.identifier} ${expected.address.slice(0, 8)}`, getAddress(await strategy.getPinnedProviderSource(expected.address, at)), expected.source);
  }
  eq('Fluid cap', await strategy.getProviderCap(fluid.address, at), plan.inputs.fluidCapBps);
  eq('GauntletPrimeV2Morpho cap', await strategy.getProviderCap(morpho.address, at), plan.inputs.morphoV2CapBps);
  eq('Fluid pinned source', getAddress(await strategy.getPinnedProviderSource(fluid.address, at)), fluid.source);
  eq('GauntletPrimeV2Morpho pinned source', getAddress(await strategy.getPinnedProviderSource(morpho.address, at)), morpho.source);
  eq('Fluid on-chain source', getAddress(await new Contract(fluid.address, PROVIDER_ABI, rpc).getSource(plan.snapshot.asset, plan.snapshot.proxy, ZeroAddress, at)), fluid.source);
  eq('GauntletPrimeV2Morpho on-chain source', getAddress(await new Contract(morpho.address, PROVIDER_ABI, rpc).getSource(plan.snapshot.asset, plan.snapshot.proxy, ZeroAddress, at)), morpho.source);
  eq('highWaterMark', await strategy.getHighWaterMark(at), plan.inputs.historicalHwm);
  eq('managementFee', await strategy.getManagementFee(at), plan.snapshot.managementFee);
  eq('performanceFee', await strategy.getPerformanceFee(at), plan.snapshot.performanceFee);
  eq('treasury', getAddress(await strategy.getTreasury(at)), plan.snapshot.treasury);
  eq('strategy timelock', getAddress(await strategy.getTimelock(at)), plan.snapshot.timelock);
  eq('asset', getAddress(await strategy.asset(at)), plan.snapshot.asset);
  eq('hasRole ADMIN', await strategy.hasRole(ADMIN_ROLE, deployer, at), true);
  eq('providersHealthy', await strategy.providersHealthy(at), true);
  eq('implementation runtime hash', keccak256(await rpc.getCode(implementation)), plan.candidates[0].expectedRuntimeHash);
  eq('totalSupply', await strategy.totalSupply(at), supplyBefore);
  const assetsAfter = BigInt(await strategy.totalAssets(at));
  const driftPpm = assetsAfter >= assetsBefore ? ((assetsAfter - assetsBefore) * 1000000n) / assetsBefore : ((assetsBefore - assetsAfter) * 1000000n) / assetsBefore;
  if (driftPpm > MAX_ASSET_DRIFT_PPM) throw new Error(`totalAssets moved ${driftPpm} ppm across registration`);
  ok('totalAssets drift', `${assetsBefore} -> ${assetsAfter} (${driftPpm} ppm)`);

  // ---- manifest ----------------------------------------------------------
  const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
  const additions: [string, string, string][] = [
    ['FluidProvider', fluid.address, deployed.FluidProvider.txHash],
    ['GauntletPrimeV2MorphoProvider', morpho.address, deployed.MorphoV2Provider.txHash],
  ];
  for (const [label, addr, tx] of additions) {
    const runtime = keccak256(await rpc.getCode(addr));
    manifest.contracts[label] = addr;
    manifest.codehashes[label] = runtime;
    manifest.txs[label] = tx;
    ok(`manifest ${label}`, `${addr} codehash ${runtime}`);
  }
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n');

  fs.writeFileSync(OUT, JSON.stringify({
    change: 'base-crosschain-upgrade',
    executedAtUtc: new Date().toISOString(),
    chainId: 8453,
    rpcHost: new globalThis.URL(RPC).host,
    signer: deployer,
    plan: path.relative(ROOT, PLAN_PATH),
    executed,
    providersAfter: providers,
    totals: { assetsBefore: assetsBefore.toString(), assetsAfter: assetsAfter.toString(), supply: supplyBefore.toString(), driftPpm: driftPpm.toString() },
    manifestUpdated: additions.map(([label]) => label),
    checks: report,
  }, null, 2));
  console.log(JSON.stringify({ ok: true, executed: executed.map((e) => ({ sig: e.signature, tx: e.txHash, block: e.blockNumber })), providers: providers.length, checks: report.length, out: path.relative(ROOT, OUT) }, null, 2));
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
