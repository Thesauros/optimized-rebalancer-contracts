/**
 * End-to-end cycle on the rehearsal forks (started by ops/rehearsal/run.sh).
 * Uses the real services (nav, keeper, relayer as child processes in --once
 * mode) and the monitor's check function, and asserts the outcome of every step.
 */
import { execFileSync, spawn } from 'child_process';
import path from 'path';
import { Contract, JsonRpcProvider, NonceManager, Wallet, id } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, STRATEGY, TICK_ACCOUNTANT } from '../src/abi';
import { loadChains, hubOf } from '../src/config';
import { runChecks } from '../src/monitor';
import { TransferIndex, verifyTick } from '../src/snapshot';
import { HUB_PARAMS, PROFILE } from '../../deploy/crosschain/registry';

const root = path.join(__dirname, '..', '..');
const USDC = (n: number) => BigInt(n) * 1_000_000n;
// amounts sized to the profile's limits (stand: 50-100 USD test stand)
const A = PROFILE === 'stand'
  ? { deposit: 100, push: 60, allocate: 20, bridge: 40, instant: 5, redeem: 10, back: 10 }
  : { deposit: 200_000, push: 150_000, allocate: 50_000, bridge: 100_000, instant: 1_000, redeem: 10_000, back: 10_000 };
const EPOCH_WAIT = Number(HUB_PARAMS.epoch.minDuration) + 60;

function service(name: string, ...extra: string[]) {
  console.log(`\n--- ${name} ${extra.join(' ')}`);
  execFileSync('npx', ['ts-node', '--transpile-only', path.join(root, 'ops', 'src', `${name}.ts`), '--once', ...extra], {
    stdio: 'inherit',
    env: { ...process.env, KEEPER_CLAIM_FOR_USERS: 'true' },
  });
}

/** The operator CLI, exactly as an operator runs it; capital moves go through it. */
function exec(...args: string[]) {
  console.log(`\n--- exec ${args.join(' ')}`);
  execFileSync('npx', ['ts-node', '--transpile-only', path.join(root, 'ops', 'src', 'exec.ts'), ...args], { stdio: 'inherit', env: process.env });
}

async function advance(providers: JsonRpcProvider[], seconds: number) {
  for (const p of providers) {
    await p.send('evm_increaseTime', [seconds]);
    // two blocks: the hub reference block (head - 1) must itself be after the jump,
    // or the snapshot is older than maxSnapshotAge, as it would be on a stalled chain
    await p.send('evm_mine', []);
    await p.send('evm_mine', []);
  }
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`ASSERTION FAILED: ${msg}`);
  console.log(`  ✓ ${msg}`);
}

async function main() {
  const chains = loadChains();
  const hub = hubOf(chains);
  const spoke = chains.find((c) => c !== hub)!;
  const providers = chains.map((c) => c.provider);

  const userWallet = new Wallet(process.env.USER_PRIVATE_KEY!, hub.provider);
  const user = new NonceManager(userWallet);
  const executorHub = new NonceManager(new Wallet(process.env.EXECUTOR_PRIVATE_KEY!, hub.provider));
  const executorSpoke = new NonceManager(new Wallet(process.env.EXECUTOR_PRIVATE_KEY!, spoke.provider));
  // services send from the same executor key in between: resync before each use
  const resync = () => { executorHub.reset(); executorSpoke.reset(); user.reset(); };
  const hc = hub.manifest.contracts;
  const sc = spoke.manifest.contracts;
  const vault = new Contract(hc.EpochVault, EPOCH_VAULT, user);
  const accountant = new Contract(hc.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const usdc = new Contract(hub.entry.usdc, ERC20, user);

  console.log(`\n== 1. user requests a ${A.deposit} USDC deposit (profile ${PROFILE})`);
  await (await usdc.approve(hc.EpochVault, USDC(A.deposit))).wait();
  await (await vault.requestDeposit(USDC(A.deposit), userWallet.address)).wait();
  const [, pending] = await vault.accounting();
  assert(BigInt(pending) === USDC(A.deposit), 'deposit is pending, not NAV');

  console.log('\n== 2. first tick (after minTickInterval since tick 0 at deployment)');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  assert(BigInt(await accountant.lastAcceptedTickId()) === 1n, 'tick 1 accepted');

  console.log('\n== 3. epoch closes after minDuration, a post-cutoff tick lands, clearing runs');
  await advance(providers, EPOCH_WAIT);
  service('keeper');
  assert(BigInt(await vault.currentEpoch()) === 2n, 'epoch 1 closed by the keeper');
  await advance(providers, 6 * 60);
  service('nav');
  service('keeper');
  const shares = BigInt(await vault.balanceOf(userWallet.address));
  assert(shares > 0n, `deposit cleared and claimed by the keeper: ${shares} shares`);

  console.log('\n== 4. executor deploys capital through the operator CLI: hub strategy + CCTP to Arbitrum');
  const hubAgent = new Contract(hc.ChainAgent, CHAIN_AGENT, hub.provider);
  exec('push', String(A.push));
  assert(BigInt(await hubAgent.idle()) === 0n, 'exec without --yes is a dry run: nothing moved');
  exec('push', String(A.push), '--yes');
  exec('allocate', hub.key, String(A.allocate), '--yes');
  exec('bridge', hub.key, spoke.key, 'all', '--tag', 'rehearsal-rebalance-1', '--yes');
  assert(BigInt(await hubAgent.idle()) === 0n, 'hub agent idle fully allocated and bridged');
  assert(A.push - A.allocate === A.bridge, 'the bridged remainder is the planned amount');
  exec('status');

  console.log('\n== 5. tick with the transfer in flight');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  const [, t3] = await accountant.latestAccepted();
  assert(BigInt(t3.navOffer) === BigInt(t3.navBid), 'in flight valued once (minReceive = amount, no spread)');

  console.log('\n== 6. relayer delivers on Arbitrum (local attester), spoke allocates');
  service('relayer');
  const spokeAgent = new Contract(sc.ChainAgent, CHAIN_AGENT, spoke.provider);
  assert(BigInt(await spokeAgent.idle()) === USDC(A.bridge), `spoke agent received exactly ${A.bridge} USDC via CCTP`);
  exec('transfers');
  exec('allocate', spoke.key, 'all', '--yes');
  const spokeStrategy = new Contract(sc.Strategy, STRATEGY, spoke.provider);
  assert(BigInt(await spokeStrategy.balanceOf(sc.ChainAgent)) > 0n, 'spoke strategy shares held by the agent');

  console.log('\n== 7. tick after delivery, independent verification, monitor');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  const lastId = BigInt(await accountant.lastAcceptedTickId());
  const index = new TransferIndex();
  const v = await verifyTick(chains, index, lastId);
  assert(v.ok, `tick ${lastId} re-derived identically by an independent verifier ${v.mismatches.join('; ')}`);
  const checks = await runChecks(chains, index, new Map());
  for (const c of checks) console.log(`  [${c.severity}] ${c.id}: ${c.message}`);
  const crit = checks.filter((c) => c.severity === 'crit');
  assert(crit.length === 0, `monitor reports no critical check (${checks.length} checks)`);

  console.log('\n== 8. user redeems part through the queue and part instantly');
  resync();
  await (await vault.instantRedeem(USDC(A.instant), userWallet.address, userWallet.address, 0)).wait();
  await (await vault.requestRedeem(USDC(A.redeem), userWallet.address, userWallet.address)).wait();
  await advance(providers, EPOCH_WAIT);
  service('nav', '--force');
  service('keeper');
  await advance(providers, 6 * 60);
  service('nav');
  service('keeper');
  const [, , liabilities] = await vault.accounting();
  assert(BigInt(liabilities) < 10n, 'redemption cleared, funded and claimed by the keeper');

  console.log('\n== 8b. return path: Arbitrum strategy -> CCTP -> Base -> vault');
  const [cashBefore] = await vault.accounting();
  exec('deallocate', spoke.key, String(A.back), '--yes');
  exec('bridge', spoke.key, hub.key, String(A.back), '--tag', 'rehearsal-return-1', '--yes');
  await advance(providers, 60);
  service('relayer');
  assert(BigInt(await hubAgent.idle()) === USDC(A.back), `hub agent received exactly ${A.back} USDC back from Arbitrum`);
  exec('return', 'all', '--yes');
  const [cashAfter] = await vault.accounting();
  assert(BigInt(cashAfter) - BigInt(cashBefore) === USDC(A.back), 'returned capital is vault cash again');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  const backId = BigInt(await accountant.lastAcceptedTickId());
  const v2 = await verifyTick(chains, new TransferIndex(), backId);
  assert(v2.ok, `tick ${backId} after the round trip re-derived identically ${v2.mismatches.join('; ')}`);
  exec('status');

  console.log('\n== 9. indexer + API');
  const port = '18085';
  const child = spawn('npx', ['ts-node', '--transpile-only', path.join(root, 'ops', 'src', 'indexer.ts')], {
    env: { ...process.env, PORT_INDEXER: port, INDEXER_DB: `/tmp/xc-indexer-${Date.now()}.sqlite`, INDEXER_POLL_SECONDS: '2' },
    stdio: 'ignore',
  });
  try {
    const api = async (p: string) => (await fetch(`http://127.0.0.1:${port}${p}`)).json() as Promise<any>;
    let healthy = false;
    for (let i = 0; i < 120 && !healthy; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      try {
        healthy = (await fetch(`http://127.0.0.1:${port}/health`)).status === 200;
      } catch {
        /* starting */
      }
    }
    assert(healthy, 'indexer healthy and synced');
    // anvil mines only on transactions: confirm the last blocks so the indexer (head - confirmations) reaches them
    for (const p of providers) {
      await p.send('evm_mine', []);
      await p.send('evm_mine', []);
    }
    const target = (await hub.provider.getBlockNumber()) - 1;
    for (let i = 0; i < 60; i++) {
      const h = await api('/health');
      if ((h.indexedTo?.base ?? 0) >= target) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    const summary = await api('/v1/vault');
    assert(summary.tick.id === Number(await accountant.lastAcceptedTickId()), `API vault summary at tick ${summary.tick.id}`);
    const u = await api(`/v1/users/${userWallet.address}`);
    const kinds = u.requests.map((r: any) => `${r.kind}:${r.state}`);
    assert(kinds.includes('deposit:claimed') && kinds.includes('redeem:claimed'), `API user requests ${kinds.join(', ')}`);
    assert(u.instantExits.length === 1, 'API shows the instant exit');
    const alloc = await api('/v1/allocation');
    assert(alloc.chains.length === 2 && BigInt(alloc.chains.find((c: any) => c.role === 'spoke').strategyValue) > 0n, 'API allocation shows capital on both chains');
    const ticks = await api('/v1/ticks?limit=50');
    assert(ticks.length >= 5, `API tick history (${ticks.length} ticks)`);
    const transfers = await api('/v1/transfers');
    assert(transfers.some((t: any) => t.state === 'delivered'), 'API shows the delivered CCTP transfer');
  } finally {
    child.kill();
  }

  console.log('\nREHEARSAL PASSED');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
