/** One-off stand governance: remove the fixed buffer and retain 5% of NAV.
 * prepare writes a public plan; queue/execute are dry runs without --yes.
 * Run execute with operators stopped, then restart them to reset their nonce cache.
 */
import fs from 'fs';
import { AbiCoder, Contract, Interface, keccak256 } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, STRATEGY, TICK_ACCOUNTANT } from './abi';
import { hubOf, loadChains, signerFor } from './config';
import { sendWithGasMargin } from './util';

const VAULT = '0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6';
const OWNER = '0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D';
const SIGNATURE = 'setLimits((uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64))';
const ABI = [
  'function owner() view returns(address)', 'function delay() view returns(uint256)',
  'function queued(bytes32) view returns(bool)',
  'function queue(address,uint256,string,bytes,uint256) returns(bytes32)',
  'function execute(address,uint256,string,bytes,uint256) payable returns(bytes)',
];
const FILE = process.env.BUFFER_PLAN_FILE ?? '/data/buffer-5pct-plan.json';
type Plan = {
  chainId: string; vault: string; timelock: string; before: string[]; after: string[];
  eta: number; data: string; id: string; txs: Record<string, string>; completed?: boolean;
};

export function bufferLimits(before: string[]): string[] {
  if (before.length !== 8) throw new Error('unexpected limits shape');
  const after = [...before];
  after[2] = '0'; after[3] = '50000000000000000';
  return after;
}
const equal = (a: string[], b: string[]) => a.join(',') === b.join(',');
function encode(after: string[]): string {
  return new Interface([`function ${SIGNATURE}`]).encodeFunctionData('setLimits', [after]).slice(10);
}
function planId(p: Plan): string {
  return keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], [p.vault, 0, SIGNATURE, p.data, p.eta],
  ));
}
export function validatePlan(p: Plan, timelock: string): void {
  if (p.chainId !== '8453' || p.vault !== VAULT || p.timelock !== timelock ||
      !equal(p.after, bufferLimits(p.before)) || p.data !== `0x${encode(p.after)}` ||
      p.id !== planId(p) || !Number.isSafeInteger(p.eta)) throw new Error('invalid or altered buffer plan');
}
function save(p: Plan): void {
  fs.writeFileSync(`${FILE}.tmp`, JSON.stringify(p, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(`${FILE}.tmp`, FILE);
}

async function main() {
  const mode = process.argv[2];
  if (!['prepare', 'queue', 'execute', 'status'].includes(mode)) throw new Error('use prepare|queue|execute|status [--yes]');
  const send = process.argv.includes('--yes');
  const hub = hubOf(loadChains());
  if (process.env.CROSSCHAIN_PROFILE !== 'stand' || process.env.OPS_LAYOUT !== 'operators' ||
      hub.chainId !== 8453n || hub.manifest.profile !== 'stand' || hub.manifest.contracts.EpochVault !== VAULT) {
    throw new Error('this operation is restricted to the existing stand');
  }
  const signer = signerFor(hub, 'EXECUTOR_PRIVATE_KEY');
  if ((await signer.getAddress()) !== OWNER) throw new Error('unexpected governance signer');
  const vault = new Contract(VAULT, [...EPOCH_VAULT, 'function getTimelock() view returns(address)', `function ${SIGNATURE}`], signer);
  const timelockAddress = await vault.getTimelock();
  if (timelockAddress !== hub.manifest.contracts.Timelock) throw new Error('timelock differs from manifest');
  const tl = new Contract(timelockAddress, ABI, signer);
  if ((await tl.owner()) !== OWNER) throw new Error('unexpected timelock owner');
  const current = Array.from(await vault.limits(), String);
  let plan: Plan;
  if (mode === 'prepare') {
    if (fs.existsSync(FILE)) throw new Error('plan already exists; inspect status instead');
    const block = (await hub.provider.getBlock('latest'))!;
    const after = bufferLimits(current);
    // Validate the target call as the actual timelock without sending a transaction.
    await hub.provider.call({ from: timelockAddress, to: VAULT, data: vault.interface.encodeFunctionData('setLimits', [after]) });
    plan = { chainId: '8453', vault: VAULT, timelock: timelockAddress, before: current, after,
      eta: block.timestamp + Number(await tl.delay()) + 600, data: `0x${encode(after)}`, id: '', txs: {} };
    plan.id = planId(plan);
    save(plan);
    console.log(JSON.stringify({ prepared: true, id: plan.id, eta: new Date(plan.eta * 1000).toISOString(), before: current, after }));
    return;
  }
  plan = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  validatePlan(plan, timelockAddress);
  const args = [plan.vault, 0, SIGNATURE, plan.data, plan.eta];
  async function write(label: string, c: Contract, method: string, params: unknown[]) {
    if (plan.txs[label]) {
      const receipt = await hub.provider.getTransactionReceipt(plan.txs[label]);
      if (!receipt || receipt.status !== 1) throw new Error(`${label}: prior transaction pending or failed; inspect ${plan.txs[label]}`);
      return;
    }
    await c[method].staticCall(...params);
    console.log(`${label}: simulation passed`);
    if (!send) return;
    const tx = await sendWithGasMargin(c, method, params);
    plan.txs[label] = tx.hash;
    save(plan);
    const receipt = await tx.wait(2);
    if (receipt?.status !== 1) throw new Error(`${label}: transaction failed`);
    console.log(`${label}: confirmed ${tx.hash}`);
  }
  if (mode === 'status') {
    console.log(JSON.stringify({ ...plan, current, queued: await tl.queued(plan.id), etaUtc: new Date(plan.eta * 1000).toISOString() }));
    return;
  }
  if (mode === 'queue') {
    if (!equal(current, plan.before)) throw new Error('limits changed after preparation');
    if (await tl.queued(plan.id)) { console.log('already queued'); return; }
    await write('queue', tl, 'queue', args);
    return;
  }
  if (plan.completed) { console.log('already completed'); return; }
  const now = (await hub.provider.getBlock('latest'))!.timestamp;
  if (now < plan.eta) throw new Error(`timelock locked until ${new Date(plan.eta * 1000).toISOString()}`);
  if (!equal(current, plan.after)) {
    if (!equal(current, plan.before)) throw new Error('other governance changed limits; refusing to overwrite');
    if (!(await tl.queued(plan.id))) throw new Error('operation is not queued');
    await write('execute', tl, 'execute', args);
    if (!send) return;
  }
  if (!equal(Array.from(await vault.limits(), String), plan.after)) throw new Error('new limits not confirmed by read RPC');
  // Deployment is allowed only against a fresh, unfrozen accepted tick and no queued exits.
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const [, tick] = await accountant.latestAccepted();
  const cfg = await accountant.config();
  const head = (await hub.provider.getBlock('latest'))!;
  if (await accountant.frozen() || await accountant.quarantined() || head.timestamp - Number(tick.committedAt) > Number(cfg.maxTickAge)) {
    throw new Error('buffer applied; allocation deferred because tick is stale or frozen');
  }
  const accounting = await vault.accounting();
  if (BigInt(accounting.liabilities) > 0n || BigInt(accounting.escrowRedeemShares) > 0n) {
    throw new Error('buffer applied; allocation deferred because withdrawals need liquidity');
  }
  const agent = new Contract(hub.manifest.contracts.ChainAgent, CHAIN_AGENT, signer);
  const strategy = new Contract(hub.manifest.contracts.Strategy, STRATEGY, hub.provider);
  if (!(await strategy.providersHealthy())) throw new Error('strategy providers unhealthy');
  const available = BigInt(await vault.freeCash()) - BigInt(await vault.minimumBuffer());
  if (available > 100_000_000n) throw new Error('allocation exceeds stand cap');
  if (available > 0n && !plan.txs.push) await write('push', vault, 'pushToAgent', [available]);
  if (!send && available > 0n) { console.log('allocate simulation follows push confirmation'); return; }
  const idle = BigInt(await agent.idle());
  if (idle > 100_000_000n) throw new Error('agent idle exceeds stand cap');
  if (idle > 0n) await write('allocate', agent, 'allocate', [idle]);
  if (send) {
    if (BigInt(await agent.idle()) !== 0n) throw new Error('allocation not yet reflected by read RPC');
    plan.completed = true; save(plan);
  }
  console.log(JSON.stringify({ completed: plan.completed ?? false, fixedBuffer: plan.after[2], ratio: plan.after[3], cash: String((await vault.accounting()).cash), txs: plan.txs }));
}

if (require.main === module) main().catch((e) => {
  const short = e?.shortMessage ?? e?.message ?? 'governance failed';
  console.error(String(short).replace(/https?:\/\/[^\s"']+/g, '[RPC_REDACTED]'));
  process.exit(1);
});
