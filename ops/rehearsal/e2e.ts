/**
 * End-to-end cycle on the rehearsal forks (started by ops/rehearsal/run.sh).
 * Uses the real services (nav, keeper, relayer as child processes in --once
 * mode) and the monitor's check function, and asserts the outcome of every step.
 */
import { execFileSync } from 'child_process';
import path from 'path';
import { Contract, JsonRpcProvider, NonceManager, Wallet, id } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, STRATEGY, TICK_ACCOUNTANT } from '../src/abi';
import { loadChains, hubOf } from '../src/config';
import { runChecks } from '../src/monitor';
import { TransferIndex, verifyTick } from '../src/snapshot';

const root = path.join(__dirname, '..', '..');
const USDC = (n: number) => BigInt(n) * 1_000_000n;

function service(name: string, ...extra: string[]) {
  console.log(`\n--- ${name} ${extra.join(' ')}`);
  execFileSync('npx', ['ts-node', '--transpile-only', path.join(root, 'ops', 'src', `${name}.ts`), '--once', ...extra], {
    stdio: 'inherit',
    env: { ...process.env, KEEPER_CLAIM_FOR_USERS: 'true' },
  });
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

  console.log('\n== 1. user requests a 200,000 USDC deposit');
  await (await usdc.approve(hc.EpochVault, USDC(200_000))).wait();
  await (await vault.requestDeposit(USDC(200_000), userWallet.address)).wait();
  const [, pending] = await vault.accounting();
  assert(BigInt(pending) === USDC(200_000), 'deposit is pending, not NAV');

  console.log('\n== 2. first tick (after minTickInterval since tick 0 at deployment)');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  assert(BigInt(await accountant.lastAcceptedTickId()) === 1n, 'tick 1 accepted');

  console.log('\n== 3. epoch closes after minDuration, a post-cutoff tick lands, clearing runs');
  await advance(providers, 4 * 3600 + 60);
  service('keeper');
  assert(BigInt(await vault.currentEpoch()) === 2n, 'epoch 1 closed by the keeper');
  await advance(providers, 6 * 60);
  service('nav');
  service('keeper');
  const shares = BigInt(await vault.balanceOf(userWallet.address));
  assert(shares > 0n, `deposit cleared and claimed by the keeper: ${shares} shares`);

  console.log('\n== 4. executor deploys capital: hub strategy + CCTP to Arbitrum');
  resync();
  const vaultX = new Contract(hc.EpochVault, EPOCH_VAULT, executorHub);
  const hubAgent = new Contract(hc.ChainAgent, CHAIN_AGENT, executorHub);
  await (await vaultX.pushToAgent(USDC(150_000))).wait();
  await (await hubAgent.allocate(USDC(50_000))).wait();
  const route = id(`thesauros.route.v1:${hub.chainId}->${spoke.chainId}`);
  await (await hubAgent.bridgeOut(route, USDC(100_000), USDC(100_000), id('rehearsal-rebalance-1'))).wait();
  assert(BigInt(await hubAgent.idle()) === 0n, 'hub agent idle fully allocated and bridged');

  console.log('\n== 5. tick with the transfer in flight');
  await advance(providers, 6 * 60);
  service('nav', '--force');
  const [, t3] = await accountant.latestAccepted();
  assert(BigInt(t3.navOffer) === BigInt(t3.navBid), 'in flight valued once (minReceive = amount, no spread)');

  console.log('\n== 6. relayer delivers on Arbitrum (local attester), spoke allocates');
  service('relayer');
  resync();
  const spokeAgent = new Contract(sc.ChainAgent, CHAIN_AGENT, executorSpoke);
  assert(BigInt(await spokeAgent.idle()) === USDC(100_000), 'spoke agent received exactly 100,000 USDC via CCTP');
  await (await spokeAgent.allocate(USDC(100_000))).wait();
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
  await (await vault.instantRedeem(USDC(1_000), userWallet.address, userWallet.address, 0)).wait();
  await (await vault.requestRedeem(USDC(10_000), userWallet.address, userWallet.address)).wait();
  await advance(providers, 4 * 3600 + 60);
  service('nav', '--force');
  service('keeper');
  await advance(providers, 6 * 60);
  service('nav');
  service('keeper');
  const [, , liabilities] = await vault.accounting();
  assert(BigInt(liabilities) < 10n, 'redemption cleared, funded and claimed by the keeper');

  console.log('\nREHEARSAL PASSED');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
