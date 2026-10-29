/** Read-only preparation/checking. No signer, key loading, broadcasting or allocation. */
import fs from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { AbiCoder, FetchRequest, Interface, JsonRpcProvider, keccak256 } from 'ethers';

export const VAULT = '0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6';
export const TIMELOCK = '0x540cAab5492014084502c1dB6F15644eedCa87ee';
export const OWNER = '0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D';
export const SIGNATURE = 'setLimits((uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64))';
export const DELAY = 86400;
export const GRACE = 14 * 86400;
const OLD_ID = '0xbc66596c64f63b5adb52066190b774b4aae716736c5c23301c313a071bc82ca4';
const OLD_ETA = 1791237841;
const vaultAbi = new Interface([
  `function ${SIGNATURE}`,
  'function limits() view returns(uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64)',
  'function getTimelock() view returns(address)',
]);
export const timelockAbi = new Interface([
  'function owner() view returns(address)', 'function delay() view returns(uint256)',
  'function GRACE_PERIOD() view returns(uint256)', 'function queued(bytes32) view returns(bool)',
  'function queue(address,uint256,string,bytes,uint256) returns(bytes32)',
  'function execute(address,uint256,string,bytes,uint256) payable returns(bytes)',
]);
// A closed read allowlist also blocks accidental wallet/broadcast RPC calls.
export class ReadOnlyProvider extends JsonRpcProvider {
  override async send(method: string, params: Array<any> | Record<string, any>): Promise<any> {
    if (!['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_call'].includes(method)) {
      throw new Error(`RPC method prohibited in unsigned preparation: ${method}`);
    }
    return super.send(method, params);
  }
}

export type Observation = {
  blockNumber: number; blockHash: string; timestamp: number;
  before: string[]; oldQueued: boolean;
};
type UnsignedTransaction = { chainId: number; from: string; to: string; value: string; data: string };
export type Plan = ReturnType<typeof buildPlan>;
const equal = (a: unknown, b: unknown) => isDeepStrictEqual(a, b);

export function targetLimits(before: string[]): string[] {
  if (!Array.isArray(before) || before.length !== 8 || before.some((value, i) =>
    typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) ||
    BigInt(value) >= (1n << (i < 6 ? 128n : 64n)))) throw new Error('invalid limits tuple');
  if (before[2] !== '5000000' || before[3] !== '100000000000000000') {
    throw new Error('expected existing 5 USDC / 10% buffer; review changed policy');
  }
  const after = [...before];
  after[2] = '0'; // Preserve the 10% ratio and every other limit exactly.
  return after;
}

export function buildPlan(observed: Observation, eta: number) {
  if (!Number.isSafeInteger(observed.blockNumber) || observed.blockNumber <= 0 ||
      !/^0x[0-9a-f]{64}$/i.test(observed.blockHash) ||
      !Number.isSafeInteger(observed.timestamp) || observed.timestamp <= 0 ||
      typeof observed.oldQueued !== 'boolean' || !Number.isSafeInteger(eta + GRACE) ||
      eta < observed.timestamp + DELAY) throw new Error('invalid observation or ETA');
  const after = targetLimits(observed.before);
  const targetCalldata = vaultAbi.encodeFunctionData('setLimits', [after]);
  const data = `0x${targetCalldata.slice(10)}`; // Timelock expects args WITHOUT selector.
  const args = [VAULT, 0, SIGNATURE, data, eta];
  const id = keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'string', 'bytes', 'uint256'], args,
  ));
  const transaction = (method: 'queue' | 'execute'): UnsignedTransaction => ({
    chainId: 8453, from: OWNER, to: TIMELOCK, value: '0',
    data: timelockAbi.encodeFunctionData(method, args),
  });
  return {
    schema: 'base-buffer-10pct-unsigned-v1',
    chainId: 8453, vault: VAULT, timelock: TIMELOCK, owner: OWNER,
    observed: { ...observed, before: [...observed.before] }, after,
    signature: SIGNATURE, data, targetCalldata, id, eta,
    etaUtc: new Date(eta * 1000).toISOString(),
    delaySeconds: DELAY, graceSeconds: GRACE,
    queueInclusionDeadline: eta - DELAY,
    queueInclusionDeadlineUtc: new Date((eta - DELAY) * 1000).toISOString(),
    executionDeadline: eta + GRACE,
    executionDeadlineUtc: new Date((eta + GRACE) * 1000).toISOString(),
    old5pctOperation: { id: OLD_ID, eta: OLD_ETA, queuedAtObservation: observed.oldQueued,
      expiredAtObservation: observed.timestamp > OLD_ETA + GRACE },
    // These are transaction requests for external review, NOT signed transactions.
    transactions: { queue: transaction('queue'), execute: transaction('execute') },
  };
}

export function validatePlan(plan: Plan): void {
  if (!equal(plan, buildPlan(plan.observed, plan.eta))) throw new Error('altered unsigned plan');
}

export function planState(plan: Plan, current: Observation, queued: boolean) {
  validatePlan(plan);
  if (equal(current.before, plan.after)) return 'target_already_applied';
  if (!equal(current.before, plan.observed.before)) throw new Error('limits changed; DO NOT sign either transaction');
  if (current.timestamp > plan.executionDeadline) return 'expired';
  if (queued) return current.timestamp < plan.eta ? 'queued_waiting' : 'ready_to_execute';
  return current.timestamp > plan.queueInclusionDeadline ? 'missed_queue_window' : 'ready_to_queue';
}

async function call(provider: ReadOnlyProvider, block: number, to: string, abi: Interface,
  method: string, args: unknown[] = [], from?: string) {
  const result = await provider.send('eth_call', [
    { to, data: abi.encodeFunctionData(method, args), ...(from ? { from } : {}) },
    `0x${block.toString(16)}`,
  ]);
  return abi.decodeFunctionResult(method, result);
}

async function observe(provider: ReadOnlyProvider): Promise<Observation> {
  if (BigInt(await provider.send('eth_chainId', [])) !== 8453n) throw new Error('wrong RPC chain');
  const block = await provider.send('eth_getBlockByNumber', ['latest', false]);
  if (!block) throw new Error('missing Base head');
  const number = Number(BigInt(block.number));
  const manifest = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../deployments/base/crosschain.json'), 'utf8'));
  if (manifest.chainId !== '8453' || manifest.profile !== 'stand' ||
      manifest.contracts.EpochVault !== VAULT || manifest.contracts.Timelock !== TIMELOCK ||
      manifest.deployer !== OWNER) throw new Error('deployment identity changed');
  const identities = ['Timelock', 'EpochVault', 'EpochVaultImplementation', 'EpochVaultLogic'];
  await Promise.all(identities.map(async name => {
    const code = await provider.send('eth_getCode', [manifest.contracts[name], block.number]);
    const expected = manifest.codehashes[name === 'EpochVault' ? 'EpochVault#proxy' : name];
    if (code === '0x' || keccak256(code) !== expected) throw new Error(`${name}: runtime code differs from manifest`);
  }));
  const [tl, owner, delay, grace, limits, oldQueued] = await Promise.all([
    call(provider, number, VAULT, vaultAbi, 'getTimelock'),
    call(provider, number, TIMELOCK, timelockAbi, 'owner'),
    call(provider, number, TIMELOCK, timelockAbi, 'delay'),
    call(provider, number, TIMELOCK, timelockAbi, 'GRACE_PERIOD'),
    call(provider, number, VAULT, vaultAbi, 'limits'),
    call(provider, number, TIMELOCK, timelockAbi, 'queued', [OLD_ID]),
  ]);
  if (tl[0] !== TIMELOCK || owner[0] !== OWNER || delay[0] !== BigInt(DELAY) || grace[0] !== BigInt(GRACE)) {
    throw new Error('governance identity or timing changed');
  }
  return { blockNumber: number, blockHash: block.hash, timestamp: Number(BigInt(block.timestamp)),
    before: Array.from(limits, String), oldQueued: oldQueued[0] };
}

async function assertCanonical(provider: ReadOnlyProvider, observed: Observation) {
  const block = await provider.send('eth_getBlockByNumber', [`0x${observed.blockNumber.toString(16)}`, false]);
  if (!block || block.hash !== observed.blockHash) throw new Error('observation block reorged; retry read-only checks');
}

async function simulate(provider: ReadOnlyProvider, plan: Plan, current: Observation, state: string) {
  await provider.send('eth_call', [
    { from: TIMELOCK, to: VAULT, data: plan.targetCalldata }, `0x${current.blockNumber.toString(16)}`,
  ]);
  const method = state === 'ready_to_queue' ? 'queue' : state === 'ready_to_execute' ? 'execute' : undefined;
  if (method) {
    const result = await call(provider, current.blockNumber, TIMELOCK, timelockAbi, method,
      [VAULT, 0, SIGNATURE, plan.data, plan.eta], OWNER);
    if (method === 'queue' && result[0] !== plan.id) throw new Error('simulated operation ID mismatch');
  }
  return { targetEthCall: 'passed', timelockEthCall: method ?? 'not attempted: not ready' };
}

async function main() {
  const [mode, file, etaArgument, ...extra] = process.argv.slice(2);
  if (!['prepare', 'check'].includes(mode) || !file || file.startsWith('-') || extra.length ||
      (mode === 'check' && etaArgument) || (etaArgument && !/^\d+$/.test(etaArgument))) {
    throw new Error('use prepare-buffer-10pct.ts prepare FILE [ETA_UNIX_SECONDS] | check FILE; no signing modes');
  }
  // No dotenv, operational config, Wallet, signer or key access.
  const request = new FetchRequest(process.env.BUFFER_READ_RPC_URL ?? 'https://mainnet.base.org');
  request.timeout = 20000;
  const provider = new ReadOnlyProvider(request, undefined, { batchMaxCount: 1, cacheTimeout: -1 });
  try {
    if (mode === 'prepare' && fs.existsSync(file)) throw new Error('output already exists; refusing to overwrite');
    const existing: Plan | undefined = mode === 'check' ? JSON.parse(fs.readFileSync(file, 'utf8')) : undefined;
    if (existing) validatePlan(existing);
    const current = await observe(provider);
    // Six hours to review/queue, plus the mandatory 24h delay; round up to 15 minutes.
    const eta = etaArgument ? Number(etaArgument) : Math.ceil((current.timestamp + DELAY + 6 * 3600) / 900) * 900;
    const plan = existing ?? buildPlan(current, eta);
    const [queued] = await call(provider, current.blockNumber, TIMELOCK, timelockAbi, 'queued', [plan.id]);
    const state = planState(plan, current, queued);
    if (mode === 'prepare' && state !== 'ready_to_queue') throw new Error(`cannot prepare: ${state}`);
    const simulations = await simulate(provider, plan, current, state);
    await assertCanonical(provider, current);
    if (mode === 'prepare') fs.writeFileSync(file, JSON.stringify(plan, null, 2) + '\n', { flag: 'wx', mode: 0o644 });
    console.log(JSON.stringify({ unsignedOnly: true, state, operationId: plan.id,
      observedBlock: current.blockNumber, queueInclusionDeadlineUtc: plan.queueInclusionDeadlineUtc,
      etaUtc: plan.etaUtc, simulations, old5pctQueued: current.oldQueued,
      old5pctExpired: current.timestamp > OLD_ETA + GRACE }, null, 2));
    if (['missed_queue_window', 'expired'].includes(state)) process.exitCode = 2;
  } finally { provider.destroy(); }
}

if (require.main === module) main().catch(error => {
  console.error(String(error?.shortMessage ?? error?.message ?? 'preparation failed')
    .replace(/https?:\/\/[^\s"']+/g, '[RPC_REDACTED]'));
  process.exitCode = 1;
});
