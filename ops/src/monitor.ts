/**
 * Monitor: continuous checks over the cross-chain system.
 *
 *   MONITOR_POLL_SECONDS      loop period (default 60)
 *   MONITOR_VERIFY_TICKS      "true" (default) to re-derive every new accepted Tick
 *   MONITOR_WATCH_BALANCES    comma list "label=address" of hot wallets to watch for gas
 *   MONITOR_MIN_GAS_WEI       warn threshold for watched wallets (default 0.005 ETH)
 *   PORT_MONITOR              status port (default 8084)
 *   TELEGRAM_TOKEN, TELEGRAM_CHAT_ID   alerts (same as Rebalance-Engine)
 *
 * Endpoints: /health (503 while any critical check fails; point the existing
 * Rebalance-Engine healthchecker at it), /status (all checks as JSON),
 * /metrics (Prometheus). Alerts fire on every state change and repeat every
 * MONITOR_REPEAT_MINUTES (default 30) while a check stays critical.
 */
import { Contract, formatUnits } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, PROVIDER, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from './abi';
import { Chain, envNumber, hubOf, identities, loadChains } from './config';
import { checkDeployment } from './checks/deployment';
import { TransferIndex, openTransferIndex, verifyTick } from './snapshot';
import { routeId } from '../../deploy/crosschain/registry';
import { log, loop, scanEvents, serveStatus, telegram } from './util';

const SERVICE = 'monitor';
type Severity = 'ok' | 'warn' | 'crit';

export interface Check {
  id: string;
  severity: Severity;
  message: string;
  value?: number;
}

const WAD = 10n ** 18n;
const usd = (v: bigint) => Number(formatUnits(v, 6));

export async function runChecks(chains: Chain[], index: TransferIndex, verified: Map<string, boolean>): Promise<Check[]> {
  const out: Check[] = [];
  const add = (id: string, severity: Severity, message: string, value?: number) => out.push({ id, severity, message, value });
  const hub = hubOf(chains);
  const now = Math.floor(Date.now() / 1000);

  // RPC liveness and head freshness
  for (const c of chains) {
    try {
      const b = await c.provider.getBlock('latest');
      const lag = now - b!.timestamp;
      add(`rpc.${c.key}`, lag > 300 ? 'crit' : lag > 60 ? 'warn' : 'ok', `${c.key} head ${b!.number}, ${lag}s old`, lag);
    } catch (e) {
      add(`rpc.${c.key}`, 'crit', `${c.key} RPC failing: ${String(e).slice(0, 120)}`);
    }
  }

  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  const usdc = new Contract(hub.entry.usdc, ERC20, hub.provider);
  const cfg = await accountant.config();
  const [latestId, latest] = await accountant.latestAccepted();
  const hubNow = (await hub.provider.getBlock('latest'))!.timestamp;

  // Ticks
  const age = hubNow - Number(latest.committedAt);
  const maxAge = Number(cfg.maxTickAge);
  add('tick.age', age > maxAge ? 'crit' : age > maxAge * 0.75 ? 'warn' : 'ok', `latest accepted tick ${latestId} is ${Math.round(age / 60)} min old (max ${maxAge / 60})`, age);
  const quarantined: boolean = await accountant.quarantined();
  const frozen: boolean = await accountant.frozen();
  add('tick.quarantine', quarantined ? 'crit' : 'ok', quarantined ? `tick ${await accountant.lastTickId()} quarantined: settlement frozen until ratify or in-bounds tick` : 'no quarantine');
  add('tick.frozen', frozen && !quarantined ? 'crit' : 'ok', frozen && !quarantined ? 'guardian freeze active' : 'not frozen');
  const flags = Number(latest.flags);
  add('tick.flag.downMove', flags & 1 ? 'warn' : 'ok', flags & 1 ? 'latest tick moved down beyond the deposit threshold: deposit clearing waits' : 'ok');
  add('tick.flag.overdue', flags & 2 ? 'crit' : 'ok', flags & 2 ? 'overdue in-flight transfers: entries and hub sends halted' : 'ok');
  add('tick.flag.inFlight', flags & 4 ? 'warn' : 'ok', flags & 4 ? 'in-flight above limit: hub sends halted' : 'ok');
  const [up, down] = await accountant.buckets();
  for (const [name, b] of [['up', up], ['down', down]] as const) {
    const level = Math.min(Number(b.capacity), Number(b.level) + (hubNow - Number(b.updatedAt)) * Number(b.refillPerSecond));
    const pct = (level / Number(b.capacity)) * 100;
    add(`tick.bucket.${name}`, pct < 10 ? 'warn' : 'ok', `${name} bucket ${pct.toFixed(0)}% available`, pct);
  }
  add('tick.rate', 'ok', `bid ${Number((BigInt(latest.rateBid) * 1_000_000n) / WAD) / 1e6}, nav ${usd(BigInt(latest.navBid)).toFixed(2)} USDC`, Number(BigInt(latest.navBid) / 1_000_000n));

  // independent re-derivation of the latest accepted tick
  if (process.env.MONITOR_VERIFY_TICKS !== 'false' && BigInt(latestId) > 0n) {
    const key = latestId.toString();
    if (!verified.has(key)) {
      try {
        const r = await verifyTick(chains, index, BigInt(latestId));
        verified.set(key, r.ok);
        if (!r.ok) log(SERVICE, 'tick verification failed', { tickId: key, mismatches: r.mismatches });
        add('tick.verify', r.ok ? 'ok' : 'crit', r.ok ? `tick ${key} re-derived identically` : `tick ${key} does not reproduce: ${r.mismatches.slice(0, 3).join('; ')}`);
      } catch (e) {
        add('tick.verify', 'warn', `tick ${key} verification error: ${String(e).slice(0, 160)}`);
      }
    } else {
      add('tick.verify', verified.get(key) ? 'ok' : 'crit', `tick ${key} ${verified.get(key) ? 'verified' : 'failed verification'}`);
    }
  }

  // Vault solvency and liquidity
  const [cash, pending, liabilities, reserved] = await vault.accounting();
  const bal: bigint = await usdc.balanceOf(hub.manifest.contracts.EpochVault);
  add('vault.solvency', BigInt(cash) >= BigInt(pending) + BigInt(reserved) ? 'ok' : 'crit', `cash ${usd(cash)} vs pending ${usd(pending)} + reserved ${usd(reserved)}`);
  add('vault.backing', bal >= BigInt(cash) ? 'ok' : 'crit', `USDC balance ${usd(bal)} vs accounted cash ${usd(cash)}`);
  const unfunded = BigInt(liabilities) - BigInt(reserved);
  add('vault.unfunded', unfunded > 0n ? 'warn' : 'ok', `unfunded cleared redemptions ${usd(unfunded)} USDC`, usd(unfunded));

  // Epochs
  const ec = await vault.epochConfig();
  const current: bigint = await vault.currentEpoch();
  const openE = await vault.getEpoch(current);
  const openFor = hubNow - Number(openE.openedAt);
  add('epoch.open', openFor > Number(ec.maxDuration) + 3600 ? 'warn' : 'ok', `epoch ${current} open ${Math.round(openFor / 60)} min (max ${Number(ec.maxDuration) / 60})`, openFor);
  const [nextDeposit, nextRedeem, nextFund] = await vault.cursors();
  for (const [name, cursor] of [['deposits', nextDeposit], ['redeems', nextRedeem]] as const) {
    if (BigInt(cursor) < current) {
      const e = await vault.getEpoch(cursor);
      const waiting = hubNow - Number(e.closedAt);
      add(`epoch.clear.${name}`, waiting > 6 * 3600 ? 'crit' : waiting > 2 * 3600 ? 'warn' : 'ok', `epoch ${cursor} ${name} uncleared for ${Math.round(waiting / 60)} min`, waiting);
    } else add(`epoch.clear.${name}`, 'ok', `${name} cleared up to epoch ${BigInt(current) - 1n}`);
  }
  if (BigInt(nextFund) < BigInt(nextRedeem)) {
    const e = await vault.getEpoch(nextFund);
    const waiting = hubNow - Number(e.closedAt);
    add('epoch.funding', waiting > 72 * 3600 ? 'crit' : waiting > 24 * 3600 ? 'warn' : 'ok', `epoch ${nextFund} redemptions (${usd(BigInt(e.assetsOwed))} USDC) unfunded for ${Math.round(waiting / 3600)} h`, waiting);
  } else add('epoch.funding', 'ok', 'all cleared redemptions funded');

  // Pauses
  const pausedDomains: number[] = [];
  for (let d = 0; d < 6; d++) if (await vault.paused(d)) pausedDomains.push(d);
  add('vault.paused', pausedDomains.length ? 'warn' : 'ok', pausedDomains.length ? `vault domains paused: ${pausedDomains.join(',')}` : 'no vault pauses');

  // Transfers in flight
  await index.sync(chains);
  let inFlightTotal = 0n;
  let oldest = 0;
  const maxTransit = Number(cfg.maxTransit);
  for (const [id, s] of index.sent) {
    if (index.received.has(id)) continue;
    const src = chains.find((c) => c.key === s.chainKey)!;
    const agent = new Contract(src.manifest.contracts.ChainAgent, CHAIN_AGENT, src.provider);
    const rec = await agent.getSent(id);
    const ageS = now - Number(rec.sentAt);
    inFlightTotal += BigInt(rec.amount) - BigInt(rec.writtenDown);
    oldest = Math.max(oldest, ageS);
    if (ageS > maxTransit) add(`transfer.${id.slice(0, 10)}`, ageS > 4 * maxTransit ? 'crit' : 'warn', `transfer ${id} from ${s.chainKey} undelivered for ${Math.round(ageS / 60)} min`, ageS);
  }
  add('transfer.inFlight', 'ok', `${usd(inFlightTotal)} USDC in flight, oldest ${Math.round(oldest / 60)} min`, usd(inFlightTotal));

  // Per chain: strategy health, exposure, route buckets, pauses
  for (const c of chains) {
    const agent = new Contract(c.manifest.contracts.ChainAgent, CHAIN_AGENT, c.provider);
    const strategy = new Contract(c.manifest.contracts.Strategy, STRATEGY, c.provider);
    const healthy: boolean = await strategy.providersHealthy();
    add(`strategy.${c.key}.health`, healthy ? 'ok' : 'crit', healthy ? `${c.key} strategy providers healthy` : `${c.key} strategy has a failing provider view: deposits blocked, NAV understated`);
    const total: bigint = await strategy.totalAssets();
    if (total > 0n) {
      for (const p of (await strategy.getProviders()) as string[]) {
        const cap = Number(await strategy.getProviderCap(p));
        if (cap === 0) continue;
        let balance = 0n;
        try {
          balance = await new Contract(p, PROVIDER, c.provider).getDepositBalance(c.manifest.contracts.Strategy, c.manifest.contracts.Strategy);
        } catch {
          continue;
        }
        const bps = Number((balance * 10_000n) / total);
        add(`strategy.${c.key}.cap.${p.slice(0, 8)}`, bps > cap ? 'warn' : 'ok', `${c.key} provider ${p} at ${bps} bps of strategy (cap ${cap})`, bps);
      }
    }
    for (const [peerKey, peer] of chains.filter((x) => x.key !== c.key).map((x) => [x.key, x] as const)) {
      const route = await agent.getRoute(routeId(c.chainId, peer.chainId));
      if (route.adapter === '0x0000000000000000000000000000000000000000') continue;
      const level = Math.min(Number(route.capacity), Number(route.level) + (now - Number(route.updatedAt)) * Number(route.refillPerSecond));
      const pct = Number(route.capacity) === 0 ? 0 : (level / Number(route.capacity)) * 100;
      add(`route.${c.key}.${peerKey}`, !route.enabled ? 'warn' : pct < 10 ? 'warn' : 'ok', `${c.key}->${peerKey} route ${route.enabled ? 'enabled' : 'DISABLED'}, bucket ${pct.toFixed(0)}%`, pct);
    }
    const agentPaused: number[] = [];
    for (const d of [0, 1]) if (await agent.paused(d)) agentPaused.push(d);
    add(`agent.${c.key}.paused`, agentPaused.length ? 'warn' : 'ok', agentPaused.length ? `${c.key} agent domains paused: ${agentPaused.join(',')}` : `${c.key} agent not paused`);
  }

  // Governance integrity and pending timelock actions
  for (const c of chains) {
    if (c.manifest.profile === 'stand') {
      add(`governance.${c.key}.standMode`, 'warn', `${c.key} runs the STAND profile: one EOA holds governance and roles; limits are stand-sized. Rotate (06-rotate-governance) before real TVL.`);
    }
  }
  const ids = identities();
  const manifests = Object.fromEntries(chains.map((c) => [c.key, c.manifest]));
  for (const c of chains) {
    if (ids.safe) {
      const results = await checkDeployment(c.provider, c.key, c.manifest, manifests, ids);
      const failed = results.filter((r) => !r.ok);
      add(`governance.${c.key}`, failed.length ? 'crit' : 'ok', failed.length ? `${c.key}: ${failed.map((f) => `${f.label} (${f.detail})`).join('; ').slice(0, 400)}` : `${c.key}: ${results.length} deployment checks pass`);
    }
    const tl = new Contract(c.manifest.contracts.Timelock, TIMELOCK, c.provider);
    const head = await c.provider.getBlockNumber();
    const from = Math.max(c.manifest.startBlock, head - envNumber('MONITOR_TIMELOCK_LOOKBACK_BLOCKS', 500_000));
    const queued = await scanEvents(tl, 'Queued', from, head);
    const done = new Set([...(await scanEvents(tl, 'Executed', from, head)), ...(await scanEvents(tl, 'Cancelled', from, head))].map((e) => e.args.txId));
    const open = queued.filter((q) => !done.has(q.args.txId));
    add(`timelock.${c.key}`, open.length ? 'warn' : 'ok', open.length ? `${c.key}: ${open.length} queued governance tx: ${open.map((q) => `${q.args.signature}@${q.args.target} eta ${new Date(Number(q.args.timestamp) * 1000).toISOString()}`).join('; ')}` : `${c.key}: no queued governance tx`);
  }

  // Hot wallet gas
  const minGas = BigInt(process.env.MONITOR_MIN_GAS_WEI ?? '5000000000000000');
  for (const item of (process.env.MONITOR_WATCH_BALANCES ?? '').split(',').filter(Boolean)) {
    const [label, address] = item.includes('=') ? item.split('=') : [item, item];
    for (const c of chains) {
      const b = await c.provider.getBalance(address);
      add(`gas.${label}.${c.key}`, b < minGas ? 'warn' : 'ok', `${label} on ${c.key}: ${formatUnits(b, 18)} ETH`, Number(formatUnits(b, 18)));
    }
  }
  return out;
}

async function main() {
  const chains = loadChains();
  const index = await openTransferIndex(chains);
  const verified = new Map<string, boolean>();
  let checks: Check[] = [];
  let lastPass = 0;
  let lastError = '';
  const previous = new Map<string, Severity>();
  const lastAlert = new Map<string, number>();
  const repeatMs = envNumber('MONITOR_REPEAT_MINUTES', 30) * 60_000;

  serveStatus(SERVICE, envNumber('PORT_MONITOR', 8084), {
    healthy: () => lastError === '' && Date.now() - lastPass < 10 * 60_000 && !checks.some((c) => c.severity === 'crit'),
    status: () => ({ lastPass: new Date(lastPass).toISOString(), lastError, checks }),
    metrics: () => {
      const sev = { ok: 0, warn: 1, crit: 2 };
      const lines = ['# HELP thesauros_check_severity 0 ok, 1 warn, 2 crit', '# TYPE thesauros_check_severity gauge'];
      for (const c of checks) lines.push(`thesauros_check_severity{check="${c.id}"} ${sev[c.severity]}`);
      lines.push('# HELP thesauros_check_value numeric value of the check', '# TYPE thesauros_check_value gauge');
      for (const c of checks) if (c.value !== undefined && Number.isFinite(c.value)) lines.push(`thesauros_check_value{check="${c.id}"} ${c.value}`);
      return lines.join('\n') + '\n';
    },
  });

  await loop(SERVICE, envNumber('MONITOR_POLL_SECONDS', 60) * 1000, async () => {
    try {
      checks = await runChecks(chains, index, verified);
      const seen = new Set<string>();
      for (const c of checks) {
        seen.add(c.id);
        const before = previous.get(c.id) ?? 'ok';
        const repeat = c.severity === 'crit' && Date.now() - (lastAlert.get(c.id) ?? 0) > repeatMs;
        if (c.severity !== before || repeat) {
          const icon = c.severity === 'crit' ? '🔴' : c.severity === 'warn' ? '🟠' : '✅';
          if (c.severity !== 'ok' || before !== 'ok') await telegram(`${icon} [thesauros crosschain] ${c.id}\n${c.message}`);
          lastAlert.set(c.id, Date.now());
        }
        previous.set(c.id, c.severity);
      }
      for (const [id, sev] of previous) if (!seen.has(id) && sev !== 'ok') {
        await telegram(`✅ [thesauros crosschain] ${id} resolved`);
        previous.set(id, 'ok');
      }
      if (process.argv.includes('--once')) console.log(JSON.stringify(checks, null, 2));
      lastPass = Date.now();
      lastError = '';
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  });
}

if (require.main === module) {
  main().catch((e) => {
    log(SERVICE, 'fatal', { error: String(e) });
    process.exit(1);
  });
}
