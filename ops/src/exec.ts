/**
 * Operator CLI for the cross-chain vault: moves capital as the executor, acts as
 * a user, and runs the keeper steps by hand. Every write is simulated first; it
 * is sent only with `--yes`, so running a command without it is a dry run.
 *
 *   npm run exec -- status
 *   npm run exec -- transfers
 *
 * Executor (EXECUTOR_PRIVATE_KEY):
 *   push <usdc>                          hub vault -> hub agent idle
 *   allocate <chain> <usdc|all>          agent idle -> strategy
 *   deallocate <chain> <usdc>            strategy -> agent idle, exact amount
 *   deallocate-all <chain> [--slippage-bps 10]
 *                                        redeem every strategy share, floor = value - slippage
 *   bridge <from> <to> <usdc|all> [--min <usdc>] [--tag <text>]
 *                                        CCTP transfer between agents; the relayer delivers.
 *                                        minReceive defaults to the full amount: standard
 *                                        CCTP transfers carry no fee
 *   return <usdc|all>                    hub agent idle -> vault (funds redemptions)
 *
 * User (USER_PRIVATE_KEY, falls back to EXECUTOR_PRIVATE_KEY):
 *   deposit <usdc>                       approve + requestDeposit
 *   redeem <shares>                      requestRedeem (shares have 6 decimals)
 *   instant <shares> [--min <usdc>]      instantRedeem
 *   claim <requestId> | cancel <requestId>
 *
 * Keeper (KEEPER_PRIVATE_KEY, falls back to EXECUTOR_PRIVATE_KEY):
 *   close | clear | fund
 *
 * RPCs and manifests come from the same environment as the services
 * (RPC_BASE, RPC_ARBITRUM, CROSSCHAIN_MANIFEST_DIR).
 */
import fs from 'fs';
import { Contract, ContractTransactionResponse, Interface, NonceManager, Wallet, formatEther, formatUnits, id, parseUnits } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, STRATEGY, TICK_ACCOUNTANT } from './abi';
import { Chain, hubOf, loadChains } from './config';
import { openTransferIndex } from './snapshot';
import { routeId } from '../../deploy/crosschain/registry';

const argv = process.argv.slice(2);
const flags = new Map<string, string>();
const args: string[] = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--yes') flags.set('yes', 'true');
  else if (argv[i].startsWith('--')) flags.set(argv[i].slice(2), argv[++i]);
  else args.push(argv[i]);
}
const SEND = flags.has('yes');

const usd = (v: bigint) => formatUnits(v, 6);
const TICK_STATUS = ['None', 'Accepted', 'Quarantined', 'Ratified'];

/** Custom errors of our contracts (src/errors.json, see scripts/extract-errors.js), so a revert names its reason. */
const errors = new Interface(require('./errors.json'));

function reason(e: any): string {
  const data: string | undefined = e?.data ?? e?.info?.error?.data ?? e?.error?.data;
  if (typeof data === 'string' && data.length >= 10) {
    try {
      const parsed = errors.parseError(data);
      if (parsed) return `${parsed.name}(${parsed.args.map(String).join(', ')})`;
    } catch {
      /* not one of ours */
    }
    return `revert data ${data}`;
  }
  return e?.shortMessage ?? e?.reason ?? String(e);
}

function chainOf(chains: Chain[], key: string | undefined): Chain {
  const c = chains.find((x) => x.key === key);
  if (!c) throw new Error(`unknown chain "${key}"; one of: ${chains.map((x) => x.key).join(', ')}`);
  return c;
}

function signer(chain: Chain, ...envKeys: string[]): NonceManager {
  for (const k of envKeys) {
    const pk = process.env[k];
    if (pk) return new NonceManager(new Wallet(pk, chain.provider));
  }
  throw new Error(`set ${envKeys.join(' or ')}`);
}

function amount(raw: string | undefined, all?: bigint): bigint {
  if (raw === undefined) throw new Error('amount missing');
  if (raw === 'all') {
    if (all === undefined) throw new Error('"all" is not accepted here');
    return all;
  }
  const v = parseUnits(raw, 6);
  if (v <= 0n) throw new Error('amount must be positive');
  return v;
}

/** Simulates, then sends only with --yes. */
async function write(label: string, c: Contract, method: string, params: unknown[]): Promise<ContractTransactionResponse | undefined> {
  try {
    await c[method].staticCall(...params);
  } catch (e) {
    throw new Error(`${label}: simulation reverts: ${reason(e)}`);
  }
  if (!SEND) {
    console.log(`  simulated OK: ${label} (dry run, add --yes to send)`);
    return undefined;
  }
  const tx: ContractTransactionResponse = await c[method](...params);
  console.log(`  sent ${label}: ${tx.hash}`);
  const r = await tx.wait();
  if (r?.status !== 1) throw new Error(`${label}: transaction failed ${tx.hash}`);
  console.log(`  confirmed in block ${r.blockNumber}`);
  return tx;
}

function contracts(chain: Chain, runner: any) {
  const m = chain.manifest.contracts;
  return {
    agent: new Contract(m.ChainAgent, CHAIN_AGENT, runner),
    strategy: new Contract(m.Strategy, STRATEGY, runner),
    vault: m.EpochVault ? new Contract(m.EpochVault, EPOCH_VAULT, runner) : undefined,
    accountant: m.TickAccountant ? new Contract(m.TickAccountant, TICK_ACCOUNTANT, runner) : undefined,
  };
}

async function status(chains: Chain[]) {
  const hub = hubOf(chains);
  const now = (await hub.provider.getBlock('latest'))!.timestamp;
  const { vault, accountant } = contracts(hub, hub.provider);
  const [latestId, latest] = await accountant!.latestAccepted();
  console.log(`== hub ${hub.key} (${hub.manifest.profile ?? 'production'} profile)`);
  console.log(
    `tick: last ${await accountant!.lastTickId()}, accepted ${latestId} (${TICK_STATUS[Number(latest.status)]}), ` +
      `${Math.round((now - Number(latest.committedAt)) / 60)} min old, rateBid ${formatUnits(latest.rateBid, 18)}, navBid ${usd(latest.navBid)} USDC`,
  );
  console.log(`breakers: frozen ${await accountant!.frozen()}, quarantined ${await accountant!.quarantined()}, hub sends allowed ${await accountant!.bridgeSendsAllowed()}`);
  const [cash, pending, liabilities, reserved] = await vault!.accounting();
  console.log(
    `vault: cash ${usd(cash)}, pending deposits ${usd(pending)}, liabilities ${usd(liabilities)}, reserved ${usd(reserved)}, ` +
      `free ${usd(await vault!.freeCash())}, buffer ${usd(await vault!.minimumBuffer())}, shares ${usd(await vault!.totalSupply())}`,
  );
  const epochId = await vault!.currentEpoch();
  const e = await vault!.getEpoch(epochId);
  const ec = await vault!.epochConfig();
  const [nextDep, nextRed, nextFund] = await vault!.cursors();
  const openFor = now - Number(e.openedAt);
  console.log(
    `epoch ${epochId}: open ${Math.round(openFor / 60)} min (closable after ${Number(ec.minDuration) / 60}, forced after ${Number(ec.maxDuration) / 60}), ` +
      `deposits ${usd(e.depositAssets)}, redeem shares ${usd(e.redeemShares)}; cursors deposit ${nextDep}, redeem ${nextRed}, fund ${nextFund}`,
  );

  for (const c of chains) {
    const { agent, strategy } = contracts(c, c.provider);
    const shares: bigint = await agent.strategyShares();
    const value: bigint = shares === 0n ? 0n : await strategy.convertToAssets(shares);
    console.log(`\n== ${c.key}`);
    console.log(`agent: idle ${usd(await agent.idle())}, strategy ${usd(value)} USDC (${shares} shares), providers healthy ${await strategy.providersHealthy()}`);
    for (const peer of chains.filter((x) => x !== c)) {
      const r = await agent.getRoute(routeId(c.chainId, peer.chainId));
      if (r.adapter === '0x0000000000000000000000000000000000000000') continue;
      const level = BigInt(r.level) + BigInt(r.refillPerSecond) * BigInt(Math.max(0, now - Number(r.updatedAt)));
      const avail = level > BigInt(r.capacity) ? BigInt(r.capacity) : level;
      console.log(`route -> ${peer.key}: ${r.enabled ? 'enabled' : 'DISABLED'}, per transfer ${usd(r.maxPerTransfer)}, available now ${usd(avail)} of ${usd(r.capacity)}`);
    }
    for (const k of ['EXECUTOR_PRIVATE_KEY', 'NAV_UPDATER_PRIVATE_KEY', 'KEEPER_PRIVATE_KEY', 'RELAYER_PRIVATE_KEY', 'USER_PRIVATE_KEY']) {
      const pk = process.env[k];
      if (!pk) continue;
      const a = new Wallet(pk).address;
      console.log(`${k.replace('_PRIVATE_KEY', '').toLowerCase()} ${a}: ${formatEther(await c.provider.getBalance(a))} ETH`);
    }
  }
}

async function transfers(chains: Chain[]) {
  const index = await openTransferIndex(chains);
  await index.sync(chains);
  const byId = new Map(chains.map((c) => [c.chainId, c.key]));
  if (index.sent.size === 0) console.log('no transfers');
  for (const [tid, s] of index.sent) {
    const r = index.received.get(tid);
    console.log(
      `${tid.slice(0, 10)}… ${s.chainKey} -> ${byId.get(s.dstChainId) ?? s.dstChainId}: ${usd(s.amount)} USDC (min ${usd(s.minReceive)}), ` +
        `sent block ${s.block}, ${r ? `DELIVERED ${usd(r.amount)} at block ${r.block}` : 'IN FLIGHT'}`,
    );
  }
}

async function main() {
  const [cmd, ...rest] = args;
  if (!cmd || cmd === 'help') {
    console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]);
    return;
  }
  const chains = loadChains();
  const hub = hubOf(chains);
  if (cmd === 'status') return status(chains);
  if (cmd === 'transfers') return transfers(chains);
  if (!SEND) console.log('DRY RUN: nothing is sent without --yes');

  switch (cmd) {
    case 'push': {
      const { vault } = contracts(hub, signer(hub, 'EXECUTOR_PRIVATE_KEY'));
      const a = amount(rest[0]);
      console.log(`push ${usd(a)} USDC from the vault to the hub agent`);
      await write('pushToAgent', vault!, 'pushToAgent', [a]);
      break;
    }
    case 'allocate':
    case 'deallocate': {
      const c = chainOf(chains, rest[0]);
      const { agent } = contracts(c, signer(c, 'EXECUTOR_PRIVATE_KEY'));
      const a = amount(rest[1], cmd === 'allocate' ? await agent.idle() : undefined);
      console.log(`${cmd} ${usd(a)} USDC on ${c.key}`);
      await write(cmd, agent, cmd, [a]);
      break;
    }
    case 'deallocate-all': {
      const c = chainOf(chains, rest[0]);
      const { agent, strategy } = contracts(c, signer(c, 'EXECUTOR_PRIVATE_KEY'));
      const shares: bigint = await agent.strategyShares();
      if (shares === 0n) throw new Error(`${c.key} agent holds no strategy shares`);
      const value: bigint = await strategy.convertToAssets(shares);
      const bps = BigInt(flags.get('slippage-bps') ?? '10');
      const min = (value * (10_000n - bps)) / 10_000n;
      console.log(`redeem ${shares} shares on ${c.key}, worth ${usd(value)} USDC, floor ${usd(min)}`);
      await write('deallocateShares', agent, 'deallocateShares', [shares, min]);
      break;
    }
    case 'bridge': {
      const src = chainOf(chains, rest[0]);
      const dst = chainOf(chains, rest[1]);
      if (src === dst) throw new Error('source and destination are the same chain');
      const { agent } = contracts(src, signer(src, 'EXECUTOR_PRIVATE_KEY'));
      const idle: bigint = await agent.idle();
      const a = amount(rest[2], idle);
      const min = flags.has('min') ? amount(flags.get('min')) : a;
      const route = routeId(src.chainId, dst.chainId);
      const r = await agent.getRoute(route);
      if (r.adapter === '0x0000000000000000000000000000000000000000') throw new Error(`no route ${src.key} -> ${dst.key}`);
      if (a > idle) throw new Error(`${src.key} agent idle is ${usd(idle)} USDC; allocate less or deallocate first`);
      const tag = id(flags.get('tag') ?? `exec:${src.key}->${dst.key}:${Date.now()}`);
      console.log(`bridge ${usd(a)} USDC ${src.key} -> ${dst.key}, minReceive ${usd(min)}, route ${route}`);
      const tx = await write('bridgeOut', agent, 'bridgeOut', [route, a, min, tag]);
      if (tx) {
        const rc = await tx.wait();
        const ev = rc!.logs.map((l) => { try { return agent.interface.parseLog(l); } catch { return null; } }).find((l) => l?.name === 'BridgeOut');
        console.log(`  transferId ${ev?.args.transferId}`);
        console.log(`  the relayer delivers it once Circle attests it (standard transfer: ~15-20 min); watch with: npm run exec -- transfers`);
      }
      break;
    }
    case 'return': {
      const { agent } = contracts(hub, signer(hub, 'EXECUTOR_PRIVATE_KEY'));
      const a = amount(rest[0], await agent.idle());
      console.log(`return ${usd(a)} USDC from the hub agent to the vault`);
      await write('returnToVault', agent, 'returnToVault', [a]);
      break;
    }
    case 'deposit': {
      const s = signer(hub, 'USER_PRIVATE_KEY', 'EXECUTOR_PRIVATE_KEY');
      const { vault } = contracts(hub, s);
      const usdc = new Contract(hub.entry.usdc, ERC20, s);
      const a = amount(rest[0]);
      const me = await s.getAddress();
      console.log(`deposit ${usd(a)} USDC from ${me}, wallet holds ${usd(await usdc.balanceOf(me))}`);
      if (SEND) {
        await write('approve', usdc, 'approve', [hub.manifest.contracts.EpochVault, a]);
      } else {
        console.log('  (approve is skipped in a dry run, so the deposit simulation may revert on allowance)');
      }
      await write('requestDeposit', vault!, 'requestDeposit', [a, me]);
      break;
    }
    case 'redeem': {
      const s = signer(hub, 'USER_PRIVATE_KEY', 'EXECUTOR_PRIVATE_KEY');
      const { vault } = contracts(hub, s);
      const me = await s.getAddress();
      const a = amount(rest[0], await vault!.balanceOf(me));
      console.log(`queue a redemption of ${usd(a)} shares for ${me}`);
      await write('requestRedeem', vault!, 'requestRedeem', [a, me, me]);
      break;
    }
    case 'instant': {
      const s = signer(hub, 'USER_PRIVATE_KEY', 'EXECUTOR_PRIVATE_KEY');
      const { vault } = contracts(hub, s);
      const me = await s.getAddress();
      const a = amount(rest[0], await vault!.balanceOf(me));
      const min = flags.has('min') ? amount(flags.get('min')) : 0n;
      console.log(`instant exit of ${usd(a)} shares for ${me}, min ${usd(min)} USDC`);
      await write('instantRedeem', vault!, 'instantRedeem', [a, me, me, min]);
      break;
    }
    case 'claim':
    case 'cancel': {
      const s = signer(hub, 'USER_PRIVATE_KEY', 'EXECUTOR_PRIVATE_KEY');
      const { vault } = contracts(hub, s);
      if (!rest[0]) throw new Error('requestId missing');
      await write(cmd, vault!, cmd, [BigInt(rest[0])]);
      break;
    }
    case 'close':
    case 'clear':
    case 'fund': {
      const { vault } = contracts(hub, signer(hub, 'KEEPER_PRIVATE_KEY', 'EXECUTOR_PRIVATE_KEY'));
      if (cmd === 'close') await write('closeEpoch', vault!, 'closeEpoch', []);
      else if (cmd === 'fund') await write('fund', vault!, 'fund', []);
      else {
        // each side is independent; one having nothing to clear is not an error
        for (const m of ['clearDeposits', 'clearRedeems']) {
          try {
            await write(m, vault!, m, []);
          } catch (e) {
            console.log(`  ${String((e as Error).message)}`);
          }
        }
      }
      break;
    }
    default:
      throw new Error(`unknown command "${cmd}"; run: npm run exec -- help`);
  }
}

main().catch((e) => {
  console.error(`error: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
