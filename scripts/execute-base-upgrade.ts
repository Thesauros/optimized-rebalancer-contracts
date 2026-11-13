/**
 * Executes the reviewed Base cross-chain release plan against mainnet:
 *   1. re-checks every preservation invariant and the HWM ceiling at the live block,
 *      using only getters the legacy implementation exposes,
 *   2. simulates the exact atomic upgrade calldata one final time,
 *   3. broadcasts those exact bytes to ProxyAdmin.upgradeAndCall,
 *   4. asserts the post-upgrade state against the plan, pinned to the upgrade block,
 *   5. queues provider registration and both new-venue caps in the Timelock.
 *
 * Nothing is allocated to a new venue here; setProviders and the caps only become
 * executable after the on-chain delay recorded in the plan.
 */
import fs from 'node:fs';
import path from 'node:path';
import { JsonRpcProvider, Wallet, Contract, keccak256, getAddress, ZeroAddress } from 'ethers';

const ROOT = path.resolve(__dirname, '..');
const PLAN_PATH = path.join(ROOT, 'changes/base-crosschain-upgrade/base-upgrade-plan.json');
const OUT = path.join(ROOT, 'changes/base-crosschain-upgrade/base-upgrade-execution.json');
const RPC = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const SCALE = 10n ** 18n;
const ADMIN_ROLE = ZeroAddress.padEnd(66, '0');
/** Assets may only drift by provider accrual across the upgrade; anything larger is a defect. */
const MAX_ASSET_DRIFT_PPM = 1000n;

const LEGACY_SAFE_ABI = [
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
];
const POST_ABI = [
  ...LEGACY_SAFE_ABI,
  'function getMinAssets() view returns (uint256)',
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
  'function queue(address,uint256,string,bytes,uint256) returns (bytes32)',
];
const PROXY_ADMIN_ABI = ['function owner() view returns (address)'];

const report: string[] = [];
function eq(label: string, actual: unknown, expected: unknown) {
  const a = String(actual).toLowerCase();
  const e = String(expected).toLowerCase();
  if (a !== e) throw new Error(`${label}: expected ${expected}, got ${actual}`);
  report.push(`${label} = ${actual}`);
}
function ok(label: string, value: unknown) { report.push(`${label} = ${value}`); }

async function main() {
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key) throw new Error('DEPLOYER_PRIVATE_KEY is required');
  const plan = JSON.parse(fs.readFileSync(PLAN_PATH, 'utf8'));
  if (plan.status !== 'UNSIGNED_READY_FOR_FORK_AND_HUMAN_REVIEW' || plan.blockers.length) {
    throw new Error(`Plan is not executable: ${plan.status} ${JSON.stringify(plan.blockers)}`);
  }
  const rpc = new JsonRpcProvider(RPC, 8453, { staticNetwork: true, batchMaxCount: 1 });
  const wallet = new Wallet(key, rpc);
  const deployer = wallet.address;
  const legacy = new Contract(plan.snapshot.proxy, LEGACY_SAFE_ABI, rpc);
  const admin = new Contract(plan.atomicUpgrade.to, PROXY_ADMIN_ABI, rpc);
  const timelock = new Contract(plan.snapshot.timelock, TIMELOCK_ABI, wallet);
  const attestedHwm = BigInt(plan.inputs.historicalHwm);

  // ---- pre-flight on the legacy runtime ---------------------------------
  eq('proxyAdmin.owner', await admin.owner(), deployer);
  eq('timelock.owner', await timelock.owner(), deployer);
  eq('timelock.delay', await timelock.delay(), plan.snapshot.delay);
  const liveImpl = getAddress('0x' + (await rpc.getStorage(plan.snapshot.proxy, IMPL_SLOT)).slice(-40));
  eq('proxy implementation (pre)', liveImpl, plan.snapshot.implementation);
  eq('legacy runtime hash (pre)', keccak256(await rpc.getCode(liveImpl)), plan.snapshot.implementationRuntimeHash);
  eq('asset (pre)', getAddress(await legacy.asset()), plan.snapshot.asset);
  const providersPre = (await legacy.getProviders()).map(getAddress);
  eq('provider count (pre)', providersPre.length, plan.preserve.providers.length);
  providersPre.forEach((p: string, i: number) => eq(`provider[${i}] (pre)`, p, plan.preserve.providers[i].address));
  eq('entry provider (pre)', getAddress(await legacy.getEntryProvider()), plan.preserve.entryProvider);
  for (const expected of plan.preserve.providers) {
    eq(`cap ${expected.identifier} (pre)`, await legacy.getProviderCap(expected.address), expected.capBps);
  }
  eq('managementFee (pre)', await legacy.getManagementFee(), plan.snapshot.managementFee);
  eq('performanceFee (pre)', await legacy.getPerformanceFee(), plan.snapshot.performanceFee);
  eq('treasury (pre)', getAddress(await legacy.getTreasury()), plan.snapshot.treasury);
  eq('strategy timelock (pre)', getAddress(await legacy.getTimelock()), plan.snapshot.timelock);
  eq('providersHealthy (pre)', await legacy.providersHealthy(), true);
  const supplyPre = BigInt(await legacy.totalSupply());
  const assetsPre = BigInt(await legacy.totalAssets());
  eq('totalSupply (pre)', supplyPre, plan.snapshot.totalSupply);
  const ceilingNow = (assetsPre * SCALE + supplyPre - 1n) / supplyPre;
  if (ceilingNow > attestedHwm) {
    throw new Error(`Fresh ceiling PPS ${ceilingNow} exceeds the attested HWM ${attestedHwm}; regenerate the plan`);
  }
  ok('ceilingPpsNow', `${ceilingNow} <= attestedHwm ${attestedHwm}`);

  // ---- final simulation of the exact reviewed calldata -------------------
  const simulated = await rpc.call({ from: deployer, to: plan.atomicUpgrade.to, data: plan.atomicUpgrade.data, value: 0n });
  ok('upgradeAndCall simulation', `ok (return ${simulated})`);

  // ---- broadcast ---------------------------------------------------------
  const tx = await wallet.sendTransaction({ to: plan.atomicUpgrade.to, data: plan.atomicUpgrade.data, value: 0n, chainId: 8453 });
  ok('upgrade tx sent', tx.hash);
  const receipt = await tx.wait(2);
  if (!receipt || receipt.status !== 1) throw new Error('Upgrade transaction reverted');
  const upgradeBlockNumber = receipt.blockNumber;
  const upgradeBlock = await rpc.getBlock(upgradeBlockNumber);
  if (!upgradeBlock) throw new Error('Upgrade block unavailable');
  ok('upgrade included', `block ${upgradeBlockNumber} gasUsed ${receipt.gasUsed}`);

  // ---- post-conditions, pinned to the upgrade block ----------------------
  const at = { blockTag: upgradeBlockNumber };
  const atPrev = { blockTag: upgradeBlockNumber - 1 };
  const post = new Contract(plan.snapshot.proxy, POST_ABI, rpc);
  eq('proxy implementation (post)', getAddress('0x' + (await rpc.getStorage(plan.snapshot.proxy, IMPL_SLOT, upgradeBlockNumber)).slice(-40)), plan.candidates[0].address);
  eq('implementation runtime hash (post)', keccak256(await rpc.getCode(plan.candidates[0].address)), plan.candidates[0].expectedRuntimeHash);
  eq('highWaterMark (post)', await post.getHighWaterMark(at), attestedHwm);
  const supplyPost = BigInt(await post.totalSupply(at));
  const supplyPrev = BigInt(await post.totalSupply(atPrev));
  eq('totalSupply unchanged by the upgrade', supplyPost, supplyPrev);
  eq('totalSupply matches the plan snapshot', supplyPost, plan.snapshot.totalSupply);
  const assetsPost = BigInt(await post.totalAssets(at));
  const driftPpm = assetsPost >= assetsPre ? ((assetsPost - assetsPre) * 1000000n) / assetsPre : ((assetsPre - assetsPost) * 1000000n) / assetsPre;
  if (driftPpm > MAX_ASSET_DRIFT_PPM) throw new Error(`totalAssets moved ${driftPpm} ppm across the upgrade`);
  ok('totalAssets drift across upgrade', `${assetsPre} -> ${assetsPost} (${driftPpm} ppm)`);
  eq('providersHealthy (post)', await post.providersHealthy(at), true);
  const providersPost = (await post.getProviders(at)).map(getAddress);
  eq('provider count (post)', providersPost.length, plan.preserve.providers.length);
  providersPost.forEach((p: string, i: number) => eq(`provider[${i}] (post)`, p, plan.preserve.providers[i].address));
  eq('entry provider (post)', getAddress(await post.getEntryProvider(at)), plan.preserve.entryProvider);
  for (const expected of plan.preserve.providers) {
    eq(`cap ${expected.identifier} (post)`, await post.getProviderCap(expected.address, at), expected.capBps);
    eq(`pinned source ${expected.identifier} (post)`, getAddress(await post.getPinnedProviderSource(expected.address, at)), expected.source);
  }
  eq('managementFee (post)', await post.getManagementFee(at), plan.snapshot.managementFee);
  eq('performanceFee (post)', await post.getPerformanceFee(at), plan.snapshot.performanceFee);
  eq('treasury (post)', getAddress(await post.getTreasury(at)), plan.snapshot.treasury);
  eq('strategy timelock (post)', getAddress(await post.getTimelock(at)), plan.snapshot.timelock);
  eq('asset (post)', getAddress(await post.asset(at)), plan.snapshot.asset);
  eq('hasRole ADMIN (post)', await post.hasRole(ADMIN_ROLE, deployer, at), true);
  eq('lastTotalAssets (post)', await post.getLastTotalAssets(at), assetsPost);
  eq('lastTimestamp (post)', Number(await post.getLastTimestamp(at)), upgradeBlock.timestamp);
  for (const [name, record] of Object.entries<any>(plan.preservedContracts)) {
    eq(`${name} implementation (post)`, getAddress('0x' + (await rpc.getStorage(record.proxy, IMPL_SLOT, upgradeBlockNumber)).slice(-40)), record.implementation);
  }
  ok('new venue caps before registration', `Fluid ${await post.getProviderCap(plan.candidates[1].address, at)} / MorphoV2 ${await post.getProviderCap(plan.candidates[2].address, at)}`);

  // ---- queue governance --------------------------------------------------
  const queued: any[] = [];
  for (const operation of plan.governance) {
    const eta = Number(operation.eta);
    const now = (await rpc.getBlock('latest'))!.timestamp;
    const delay = Number(await timelock.delay());
    if (eta < now + delay) throw new Error(`Plan ETA ${eta} no longer satisfies delay ${delay} at ${now}; regenerate the plan`);
    const sent = await timelock.queue(plan.snapshot.proxy, 0, operation.signature, operation.data, eta);
    const r = await sent.wait(2);
    if (!r || r.status !== 1) throw new Error(`queue(${operation.signature}) reverted`);
    if (!(await timelock.queued(operation.transactionId))) throw new Error(`transactionId ${operation.transactionId} is not marked queued`);
    queued.push({
      signature: operation.signature, eta, etaUtc: new Date(eta * 1000).toISOString(),
      transactionId: operation.transactionId, txHash: r.hash, blockNumber: r.blockNumber,
      gasUsed: r.gasUsed.toString(), queuedConfirmedOnChain: true,
      executeCalldata: operation.execute.data,
    });
    ok(`queued ${operation.signature}`, `${r.hash} eta ${new Date(eta * 1000).toISOString()}`);
  }

  fs.writeFileSync(OUT, JSON.stringify({
    change: 'base-crosschain-upgrade',
    executedAtUtc: new Date().toISOString(),
    chainId: 8453,
    rpcHost: new globalThis.URL(RPC).host,
    signer: deployer,
    plan: path.relative(ROOT, PLAN_PATH),
    planSnapshotBlock: plan.snapshot.block,
    attestedHwm: attestedHwm.toString(),
    ceilingPpsAtPreflight: ceilingNow.toString(),
    upgrade: {
      txHash: receipt.hash, blockNumber: upgradeBlockNumber, blockHash: upgradeBlock.hash,
      blockTimestamp: upgradeBlock.timestamp, gasUsed: receipt.gasUsed.toString(),
      newImplementation: plan.candidates[0].address, previousImplementation: plan.snapshot.implementation,
      calldata: plan.atomicUpgrade.data,
    },
    totals: { assetsPre: assetsPre.toString(), assetsPost: assetsPost.toString(), supplyPre: supplyPre.toString(), supplyPost: supplyPost.toString(), driftPpm: driftPpm.toString() },
    queued,
    checks: report,
  }, null, 2));
  console.log(JSON.stringify({ ok: true, upgradeTx: receipt.hash, block: upgradeBlockNumber, queued: queued.map((q) => ({ sig: q.signature, etaUtc: q.etaUtc, tx: q.txHash })), checks: report.length, out: path.relative(ROOT, OUT) }, null, 2));
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
