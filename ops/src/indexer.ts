/**
 * Indexer + read API for the cross-chain vault (frontend, dashboards, partners).
 *
 *   INDEXER_DB             SQLite file (default ./crosschain-indexer.sqlite); a cache,
 *                          fully rebuildable from chain events (delete it to reindex)
 *   INDEXER_POLL_SECONDS   default 15
 *   PORT_INDEXER           HTTP port (default 8085)
 *   INDEXER_CORS_ORIGIN    Access-Control-Allow-Origin (default *)
 *
 * Endpoints (JSON, amounts as decimal strings in asset/share base units):
 *   GET /health
 *   GET /v1/vault                     summary: rates, NAV, epoch timing, limits, APR
 *   GET /v1/instant-remaining          SQLite-only instant-exit bucket estimate
 *   GET /v1/users/:address            share balance and every request with its derived status
 *   GET /v1/requests/:id
 *   GET /v1/epochs?limit=20
 *   GET /v1/ticks?limit=200           NAV / rate history (accepted and quarantined)
 *   GET /v1/allocation                capital per chain / strategy / provider + in flight
 *   GET /v1/transfers?limit=50
 *   GET /v1/activity?limit=50         one chronological feed of everything that happened
 *
 * Source of truth is the chain: events are indexed up to head - confirmations
 * and live state (balances, epochs, accounting) is read on request.
 */
import http from 'http';
import { DatabaseSync } from 'node:sqlite';
import { Contract, getAddress, isAddress } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, PROVIDER, STRATEGY, TICK_ACCOUNTANT } from './abi';
import { Chain, envNumber, hubOf, loadChains } from './config';
import type { NetworkEntry } from '../../deploy/crosschain/registry';
import { log, loop, retryTransient, scanMany, semaphore } from './util';

const SERVICE = 'indexer';
const WAD = 10n ** 18n;
const YEAR = 365 * 24 * 3600;

const gate = semaphore(envNumber('RPC_CONCURRENCY', 4));

/**
 * One live provider read.
 *
 * Bounded, because a page load fires /v1/vault and /v1/allocation together and an unbounded
 * Promise.all opens one socket per call at the same instant, which the endpoint drops. Retried,
 * because the drops also happen on their own. Each attempt takes the gate separately, so a call
 * waiting to retry does not hold a slot.
 */
const rpc = <T>(fn: () => Promise<T>) => retryTransient(() => gate(fn));

const POLL_SECONDS = envNumber('INDEXER_POLL_SECONDS', 15);

/*//////////////////////////////////////////////////////////////
                    PURE DERIVATIONS (unit-tested)
//////////////////////////////////////////////////////////////*/

export interface EpochLike {
  closedAt: bigint;
  depositsCleared: boolean;
  redeemsCleared: boolean;
  funded: boolean;
  rateOffer: bigint;
  priceRedeem: bigint;
}

export type RequestState = 'pending' | 'clearing' | 'awaiting_liquidity' | 'claimable' | 'claimed' | 'cancelled';

/** One line of the public activity feed; which optional fields are set depends on `type`. */
export type ActivityType =
  | 'deposit_requested'
  | 'deposit_claimed'
  | 'redeem_requested'
  | 'redeem_claimed'
  | 'request_cancelled'
  | 'instant_exit'
  | 'tick_accepted'
  | 'tick_quarantined'
  | 'tick_ratified'
  | 'bridge_sent'
  | 'bridge_arrived';

export interface ActivityItem {
  time: number;
  type: ActivityType;
  tx: string | null;
  requestId?: number;
  kind?: 'deposit' | 'redeem';
  epoch?: number;
  owner?: string;
  receiver?: string;
  amount?: string;
  tickId?: number;
  rateBid?: string;
  navBid?: string;
  srcChain?: number;
  dstChain?: number;
  shares?: string;
  assets?: string;
}

/** Status of a request as a user sees it, from the stored status and its epoch. */
export function deriveRequest(
  kind: 'deposit' | 'redeem',
  storedStatus: 'requested' | 'cancelled' | 'claimed',
  amount: bigint,
  epochId: bigint,
  currentEpoch: bigint,
  e: EpochLike,
): { state: RequestState; cancellable: boolean; claimable: bigint } {
  if (storedStatus === 'cancelled') return { state: 'cancelled', cancellable: false, claimable: 0n };
  if (storedStatus === 'claimed') return { state: 'claimed', cancellable: false, claimable: 0n };
  if (epochId === currentEpoch) return { state: 'pending', cancellable: true, claimable: 0n };
  if (kind === 'deposit') {
    // A deposit stays cancellable until it is priced, past the cutoff included: the refund is
    // NAV-neutral, and this is the only exit for a deposit caught in a frozen or quarantined
    // epoch (EpochVaultLogic.cancel). A redeem is not cancellable past the cutoff, because its
    // price is fixed only at clearing and a late cancel would be a free option on the epoch.
    if (!e.depositsCleared) return { state: 'clearing', cancellable: true, claimable: 0n };
    return { state: 'claimable', cancellable: false, claimable: (amount * WAD) / e.rateOffer };
  }
  if (!e.redeemsCleared) return { state: 'clearing', cancellable: false, claimable: 0n };
  const assets = (amount * e.priceRedeem) / WAD;
  return { state: e.funded ? 'claimable' : 'awaiting_liquidity', cancellable: false, claimable: assets };
}

/** Replays instant exits through the daily bucket (capacity = daily limit, refill per day). */
export function instantRemaining(dailyLimit: bigint, exits: { time: number; assets: bigint }[], now: number): bigint {
  let level = dailyLimit;
  let last = exits.length ? exits[0].time : now;
  for (const x of exits) {
    level += (BigInt(x.time - last) * dailyLimit) / 86_400n;
    if (level > dailyLimit) level = dailyLimit;
    level = level > x.assets ? level - x.assets : 0n;
    last = x.time;
  }
  level += (BigInt(Math.max(0, now - last)) * dailyLimit) / 86_400n;
  return level > dailyLimit ? dailyLimit : level;
}

/** Annualized bid-rate growth between two ticks, as a fraction (0.05 = 5%). */
export function annualized(rateThen: bigint, rateNow: bigint, seconds: number): number | null {
  if (rateThen === 0n || seconds < 3600) return null;
  const growth = Number((rateNow * 1_000_000_000n) / rateThen) / 1e9;
  return Math.pow(growth, YEAR / seconds) - 1;
}

/**
 * Registry label for a provider address.
 *
 * `getIdentifier()` is not enough: three different Morpho vaults on one chain all report
 * `Morpho_Provider`, so a consumer cannot tell them apart. The registry already names them,
 * and Compound V3 is named by its manifest entry, so the label is stable per deployment.
 */
export function providerLabel(entry: NetworkEntry, manifestContracts: Record<string, string>, address: string): string | null {
  const a = address.toLowerCase();
  const reused = entry.strategy?.reusedProviders?.find((p) => p.address.toLowerCase() === a);
  if (reused) return reused.label;
  const deployed = Object.keys(manifestContracts).find((k) => manifestContracts[k].toLowerCase() === a);
  return deployed ? deployed.replace(/Provider$/, '') : null;
}

/*//////////////////////////////////////////////////////////////
                               STORE
//////////////////////////////////////////////////////////////*/

const SCHEMA = `
create table if not exists meta (key text primary key, value text not null);
create table if not exists requests (
  id integer primary key, kind text not null, owner text not null, receiver text not null,
  epoch integer not null, amount text not null, status text not null,
  requested_tx text, requested_at integer, cancelled_tx text, cancelled_at integer, claimed_tx text, claimed_amount text, claimed_at integer);
create index if not exists requests_owner on requests(owner);
create index if not exists requests_receiver on requests(receiver);
create table if not exists ticks (
  id integer primary key, status integer not null, flags integer not null, reference_time integer not null,
  hub_block integer not null, rate_bid text not null, rate_offer text not null, nav_bid text not null,
  nav_offer text not null, nav_hash text not null, committed_at integer not null, tx text not null);
create table if not exists instants (
  tx text primary key, owner text not null, receiver text not null, tick integer not null,
  shares text not null, assets text not null, time integer not null);
create table if not exists transfers (
  id text primary key, src_chain integer, dst_chain integer, amount text, min_receive text,
  rebalance_id text, sent_tx text, sent_at integer, received_amount text, received_tx text,
  received_at integer, written_down text default '0');
`;

export class Indexer {
  readonly db: DatabaseSync;
  readonly hub: Chain;
  private blockTime = new Map<string, number>();

  constructor(readonly chains: Chain[], dbPath: string) {
    this.db = new DatabaseSync(dbPath);
    this.db.exec(SCHEMA);
    // The DB is a rebuildable cache, but an existing file predates cancelled_at.
    const cols = this.db.prepare("select name from pragma_table_info('requests')").all() as { name: string }[];
    if (!cols.some((c) => c.name === 'cancelled_at')) this.db.exec('alter table requests add column cancelled_at integer');
    this.hub = hubOf(chains);
  }

  private meta(key: string): number | undefined {
    const row = this.db.prepare('select value from meta where key = ?').get(key) as { value: string } | undefined;
    return row ? Number(row.value) : undefined;
  }

  private setMeta(key: string, v: number) {
    this.db.prepare('insert into meta(key, value) values (?, ?) on conflict(key) do update set value = excluded.value').run(key, String(v));
  }

  private async ts(c: Chain, block: number): Promise<number> {
    const k = `${c.key}:${block}`;
    let t = this.blockTime.get(k);
    if (t === undefined) {
      t = (await c.provider.getBlock(block))!.timestamp;
      this.blockTime.set(k, t);
      if (this.blockTime.size > 50_000) this.blockTime.clear();
    }
    return t;
  }

  /** Indexes every chain up to head - confirmations. */
  async sync(): Promise<void> {
    for (const c of this.chains) {
      const conf = Number(process.env[`CONFIRMATIONS_${c.key.toUpperCase()}`] ?? c.entry.confirmations);
      const head = (await c.provider.getBlockNumber()) - conf;
      const from = (this.meta(`block:${c.key}`) ?? c.manifest.startBlock - 1) + 1;
      if (from > head) continue;
      if (c === this.hub) await this.syncHub(from, head);
      await this.syncAgent(c, from, head);
      this.setMeta(`block:${c.key}`, head);
    }
  }

  private async syncHub(from: number, to: number) {
    const c = this.hub;
    const vault = new Contract(c.manifest.contracts.EpochVault, EPOCH_VAULT_EVENTS, c.provider);
    const accountant = new Contract(c.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, c.provider);
    const vaultEvents = ['DepositRequested', 'RedeemRequested', 'RequestCancelled', 'DepositClaimed', 'RedeemClaimed', 'InstantRedeemed'];
    for (const e of await scanMany(vault, vaultEvents, from, to)) {
      switch (e.eventName) {
        case 'DepositRequested':
        case 'RedeemRequested': {
          const deposit = e.eventName === 'DepositRequested';
          this.db.prepare('insert or ignore into requests(id, kind, owner, receiver, epoch, amount, status, requested_tx, requested_at) values (?,?,?,?,?,?,?,?,?)')
            .run(Number(e.args.requestId), deposit ? 'deposit' : 'redeem', e.args.owner.toLowerCase(), e.args.receiver.toLowerCase(), Number(e.args.epoch), (deposit ? e.args.assets : e.args.shares).toString(), 'requested', e.transactionHash, await this.ts(c, e.blockNumber));
          break;
        }
        case 'RequestCancelled':
          this.db.prepare("update requests set status = 'cancelled', cancelled_tx = ?, cancelled_at = ? where id = ?").run(e.transactionHash, await this.ts(c, e.blockNumber), Number(e.args.requestId));
          break;
        case 'DepositClaimed':
        case 'RedeemClaimed': {
          const amount = e.eventName === 'DepositClaimed' ? e.args.shares : e.args.assets;
          this.db.prepare("update requests set status = 'claimed', claimed_tx = ?, claimed_amount = ?, claimed_at = ? where id = ?")
            .run(e.transactionHash, amount.toString(), await this.ts(c, e.blockNumber), Number(e.args.requestId));
          break;
        }
        case 'InstantRedeemed':
          this.db.prepare('insert or ignore into instants(tx, owner, receiver, tick, shares, assets, time) values (?,?,?,?,?,?,?)')
            .run(e.transactionHash, e.args.owner.toLowerCase(), e.args.receiver.toLowerCase(), Number(e.args.tickId), e.args.shares.toString(), e.args.assets.toString(), await this.ts(c, e.blockNumber));
          break;
      }
    }
    for (const e of await scanMany(accountant, ['TickCommitted', 'TickRatified'], from, to)) {
      if (e.eventName === 'TickRatified') {
        this.db.prepare('update ticks set status = 3 where id = ?').run(Number(e.args.tickId));
        continue;
      }
      this.db.prepare('insert or replace into ticks(id, status, flags, reference_time, hub_block, rate_bid, rate_offer, nav_bid, nav_offer, nav_hash, committed_at, tx) values (?,?,?,?,?,?,?,?,?,?,?,?)')
        .run(Number(e.args.tickId), Number(e.args.status), Number(e.args.flags), Number(e.args.referenceTime), Number(e.args.hubBlock), e.args.rateBid.toString(), e.args.rateOffer.toString(), e.args.navBid.toString(), e.args.navOffer.toString(), e.args.navHash, await this.ts(c, e.blockNumber), e.transactionHash);
    }
  }

  private async syncAgent(c: Chain, from: number, to: number) {
    const agent = new Contract(c.manifest.contracts.ChainAgent, CHAIN_AGENT, c.provider);
    for (const e of await scanMany(agent, ['BridgeOut', 'BridgeIn', 'WrittenDown'], from, to)) {
      if (e.eventName === 'BridgeOut') {
        this.db.prepare('insert into transfers(id, src_chain, dst_chain, amount, min_receive, rebalance_id, sent_tx, sent_at) values (?,?,?,?,?,?,?,?) on conflict(id) do update set src_chain = excluded.src_chain, dst_chain = excluded.dst_chain, amount = excluded.amount, min_receive = excluded.min_receive, rebalance_id = excluded.rebalance_id, sent_tx = excluded.sent_tx, sent_at = excluded.sent_at')
          .run(e.args.transferId, Number(c.chainId), Number(e.args.dstChainId), e.args.amount.toString(), e.args.minReceive.toString(), e.args.rebalanceId, e.transactionHash, await this.ts(c, e.blockNumber));
      } else if (e.eventName === 'BridgeIn') {
        this.db.prepare('insert into transfers(id, received_amount, received_tx, received_at) values (?,?,?,?) on conflict(id) do update set received_amount = excluded.received_amount, received_tx = excluded.received_tx, received_at = excluded.received_at')
          .run(e.args.transferId, e.args.amount.toString(), e.transactionHash, await this.ts(c, e.blockNumber));
      } else {
        this.db.prepare('update transfers set written_down = ? where id = ?').run(e.args.totalWrittenDown.toString(), e.args.transferId);
      }
    }
  }

  lag(): Record<string, number | undefined> {
    return Object.fromEntries(this.chains.map((c) => [c.key, this.meta(`block:${c.key}`)]));
  }

  /*//////////////////////////////////////////////////////////////
                                 API
  //////////////////////////////////////////////////////////////*/

  private vault() {
    return new Contract(this.hub.manifest.contracts.EpochVault, EPOCH_VAULT, this.hub.provider);
  }

  private async epochs(ids: bigint[]): Promise<Map<string, any>> {
    const vault = this.vault();
    const unique = [...new Set(ids.map(String))];
    const rows = await Promise.all(unique.map((id) => rpc(() => vault.getEpoch(BigInt(id)))));
    return new Map(unique.map((id, i) => [id, rows[i]]));
  }

  async vaultSummary() {
    const vault = this.vault();
    const accountant = new Contract(this.hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, this.hub.provider);
    // Every read except getEpoch(current) is independent, and providers are constructed with
    // batchMaxCount: 1, so awaiting them one by one is one HTTP round trip each. Issued
    // together this is two waves instead of fourteen, which is the difference between a
    // dashboard that renders and one that appears to hang.
    const [latest, block, current, ec, l, cfg, acct, asset, symbol, totalSupply, frozen, quarantined, freeCash] = await Promise.all([
      rpc(() => accountant.latestAccepted() as Promise<[bigint, any]>),
      rpc(() => this.hub.provider.getBlock('latest')),
      rpc(() => vault.currentEpoch() as Promise<bigint>),
      rpc(() => vault.epochConfig()),
      rpc(() => vault.limits()),
      rpc(() => accountant.config()),
      rpc(() => vault.accounting() as Promise<[bigint, bigint, bigint, bigint, bigint, bigint]>),
      rpc(() => vault.asset() as Promise<string>),
      rpc(() => vault.symbol() as Promise<string>),
      rpc(() => vault.totalSupply() as Promise<bigint>),
      rpc(() => accountant.frozen() as Promise<boolean>),
      rpc(() => accountant.quarantined() as Promise<boolean>),
      rpc(() => vault.freeCash() as Promise<bigint>),
    ]);
    const [tickId, tick] = latest;
    const now = block!.timestamp;
    const e = await rpc(() => vault.getEpoch(current));
    const [cash, pending, liabilities, reserved] = acct;
    const aprOver = (days: number) => {
      const row = this.db.prepare('select rate_bid, committed_at from ticks where status in (1,3) and committed_at <= ? order by committed_at desc limit 1').get(now - days * 86400) as { rate_bid: string; committed_at: number } | undefined;
      const first = row ?? (this.db.prepare('select rate_bid, committed_at from ticks where status in (1,3) order by committed_at asc limit 1').get() as { rate_bid: string; committed_at: number } | undefined);
      return first ? annualized(BigInt(first.rate_bid), BigInt(tick.rateBid), Number(tick.committedAt) - first.committed_at) : null;
    };
    return {
      chainId: Number(this.hub.chainId),
      vault: this.hub.manifest.contracts.EpochVault,
      asset,
      symbol,
      decimals: 6,
      profile: this.hub.manifest.profile ?? 'production',
      totalSupply: totalSupply.toString(),
      tick: {
        id: Number(tickId),
        rateBid: tick.rateBid.toString(),
        rateOffer: tick.rateOffer.toString(),
        navBid: tick.navBid.toString(),
        navOffer: tick.navOffer.toString(),
        committedAt: Number(tick.committedAt),
        // Tick 0 is the synthetic launch tick: nothing has been published yet, so there is no
        // age to report and `now - 0` would be a meaningless ~1.79e9 seconds.
        ageSeconds: tickId > 0n ? now - Number(tick.committedAt) : null,
        flags: Number(tick.flags),
        frozen,
        quarantined,
      },
      /** Thresholds a consumer needs to judge the tick and the in-flight capital honestly. */
      risk: {
        maxTickAge: Number(cfg.maxTickAge),
        maxTransit: Number(cfg.maxTransit),
        maxSpread: cfg.maxSpread.toString(),
        maxInFlightRatio: cfg.maxInFlightRatio.toString(),
      },
      apr: { d7: aprOver(7), d30: aprOver(30) },
      epoch: {
        id: Number(current),
        openedAt: Number(e.openedAt),
        earliestCloseAt: Number(e.openedAt) + Number(ec.minDuration),
        latestCloseAt: Number(e.openedAt) + Number(ec.maxDuration),
        depositAssets: e.depositAssets.toString(),
        redeemShares: e.redeemShares.toString(),
      },
      accounting: { cash: cash.toString(), pendingDeposits: pending.toString(), liabilities: liabilities.toString(), reserved: reserved.toString(), freeCash: freeCash.toString() },
      limits: {
        minDeposit: l.minDeposit.toString(),
        maxEpochDeposits: l.maxEpochDeposits.toString(),
        // The buffer pair is what bounds capital utilization: pushToAgent refuses to leave less
        // than max(minimumBuffer, minBufferRatio * navBid) in the vault, so a consumer cannot
        // explain "why is cash idle" without them.
        minimumBuffer: l.minimumBuffer.toString(),
        minBufferRatio: l.minBufferRatio.toString(),
        maxInstantWithdrawal: l.maxInstantWithdrawal.toString(),
        dailyInstantLimit: l.dailyInstantLimit.toString(),
        instantFee: l.instantFee.toString(),
        instantRemainingEstimate: this.instantRemainingEstimate(BigInt(l.dailyInstantLimit), now),
      },
      epochConfig: { minDuration: Number(ec.minDuration), maxDuration: Number(ec.maxDuration), minTicks: Number(ec.minTicks), maxClearingDelay: Number(ec.maxClearingDelay) },
      now,
    };
  }

  /** Cheap allocator read: the daily limit is already known on-chain by the caller. */
  instantRemainingEstimate(dailyLimit: bigint, now = Math.floor(Date.now() / 1000)): string {
    const exits = (this.db.prepare('select time, assets from instants order by time').all() as { time: number; assets: string }[])
      .map((x) => ({ time: x.time, assets: BigInt(x.assets) }));
    return instantRemaining(dailyLimit, exits, now).toString();
  }

  private async requestViews(rows: any[]) {
    const vault = this.vault();
    const current: bigint = await rpc(() => vault.currentEpoch() as Promise<bigint>);
    const epochs = await this.epochs(rows.map((r) => BigInt(r.epoch)));
    return rows.map((r) => {
      const e = epochs.get(String(r.epoch));
      const d = deriveRequest(r.kind, r.status, BigInt(r.amount), BigInt(r.epoch), current, {
        closedAt: BigInt(e.closedAt),
        depositsCleared: e.depositsCleared,
        redeemsCleared: e.redeemsCleared,
        funded: e.funded,
        rateOffer: BigInt(e.rateOffer),
        priceRedeem: BigInt(e.priceRedeem),
      });
      return {
        id: r.id,
        kind: r.kind,
        owner: r.owner,
        receiver: r.receiver,
        epoch: r.epoch,
        amount: r.amount,
        state: d.state,
        cancellable: d.cancellable,
        claimable: d.claimable.toString(),
        claimedAmount: r.claimed_amount,
        requestedAt: r.requested_at,
        requestedTx: r.requested_tx,
        claimedTx: r.claimed_tx,
        epochClosedAt: Number(e.closedAt) || null,
      };
    });
  }

  async user(address: string) {
    const a = address.toLowerCase();
    const vault = this.vault();
    const accountant = new Contract(this.hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, this.hub.provider);
    const [latest, shares] = await Promise.all([
      rpc(() => accountant.latestAccepted() as Promise<[bigint, any]>),
      rpc(() => vault.balanceOf(getAddress(address)) as Promise<bigint>),
    ]);
    const [, tick] = latest;
    const rows = this.db.prepare('select * from requests where owner = ? or receiver = ? order by id desc limit 200').all(a, a);
    const instants = this.db.prepare('select * from instants where owner = ? or receiver = ? order by time desc limit 50').all(a, a);
    return {
      address: getAddress(address),
      shares: shares.toString(),
      valueBid: ((shares * BigInt(tick.rateBid)) / WAD).toString(),
      requests: await this.requestViews(rows),
      instantExits: instants,
    };
  }

  async request(id: number) {
    const rows = this.db.prepare('select * from requests where id = ?').all(id);
    return rows.length ? (await this.requestViews(rows))[0] : null;
  }

  async epochList(limit: number) {
    const vault = this.vault();
    const current = Number(await rpc(() => vault.currentEpoch() as Promise<bigint>));
    const ids: number[] = [];
    for (let id = current; id >= Math.max(1, current - limit + 1); id--) ids.push(id);
    const rows = await Promise.all(ids.map((id) => rpc(() => vault.getEpoch(id))));
    return rows.map((e, i) => ({
      id: ids[i],
      openedAt: Number(e.openedAt),
      closedAt: Number(e.closedAt) || null,
      openRateBid: e.openRateBid.toString(),
      depositAssets: e.depositAssets.toString(),
      redeemShares: e.redeemShares.toString(),
      depositsCleared: e.depositsCleared,
      redeemsCleared: e.redeemsCleared,
      funded: e.funded,
      rateOffer: e.rateOffer.toString(),
      priceRedeem: e.priceRedeem.toString(),
      sharesMinted: e.sharesMinted.toString(),
      assetsOwed: e.assetsOwed.toString(),
      depositTickId: Number(e.depositTickId) || null,
      redeemTickId: Number(e.redeemTickId) || null,
    }));
  }

  ticks(limit: number) {
    return this.db.prepare('select * from ticks order by id desc limit ?').all(limit);
  }

  transfers(limit: number) {
    return (this.db.prepare('select * from transfers order by sent_at desc limit ?').all(limit) as any[]).map((t) => ({
      ...t,
      state: t.received_tx ? 'delivered' : t.sent_tx ? 'in_flight' : 'unknown',
    }));
  }

  /**
   * One chronological feed of everything the system did, newest first.
   *
   * Pure SQLite, no RPC, so it is cheap enough for a browser to poll. Every source is limited
   * to its own newest `limit` rows before the merge, which makes the returned window exact:
   * the newest `limit` items overall cannot contain more than `limit` items from one source.
   */
  activity(limit: number): ActivityItem[] {
    const out: ActivityItem[] = [];

    const requested = this.db.prepare('select id, kind, owner, receiver, epoch, amount, requested_tx as tx, requested_at as time from requests where requested_at is not null order by requested_at desc limit ?').all(limit) as any[];
    for (const r of requested) {
      out.push({ time: r.time, type: r.kind === 'deposit' ? 'deposit_requested' : 'redeem_requested', tx: r.tx, requestId: r.id, kind: r.kind, epoch: r.epoch, owner: r.owner, receiver: r.receiver, amount: r.amount });
    }

    const claimed = this.db.prepare('select id, kind, owner, receiver, epoch, claimed_amount as amount, claimed_tx as tx, claimed_at as time from requests where claimed_at is not null order by claimed_at desc limit ?').all(limit) as any[];
    for (const r of claimed) {
      out.push({ time: r.time, type: r.kind === 'deposit' ? 'deposit_claimed' : 'redeem_claimed', tx: r.tx, requestId: r.id, kind: r.kind, epoch: r.epoch, owner: r.owner, receiver: r.receiver, amount: r.amount });
    }

    const cancelled = this.db.prepare('select id, kind, owner, receiver, epoch, amount, cancelled_tx as tx, cancelled_at as time from requests where cancelled_at is not null order by cancelled_at desc limit ?').all(limit) as any[];
    for (const r of cancelled) {
      out.push({ time: r.time, type: 'request_cancelled', tx: r.tx, requestId: r.id, kind: r.kind, epoch: r.epoch, owner: r.owner, receiver: r.receiver, amount: r.amount });
    }

    const instants = this.db.prepare('select tx, owner, receiver, tick, shares, assets, time from instants order by time desc limit ?').all(limit) as any[];
    for (const r of instants) {
      out.push({ time: r.time, type: 'instant_exit', tx: r.tx, owner: r.owner, receiver: r.receiver, tickId: r.tick, shares: r.shares, assets: r.assets, amount: r.assets });
    }

    const ticks = this.db.prepare('select id, status, rate_bid, nav_bid, committed_at as time, tx from ticks where status in (1, 2, 3) order by committed_at desc limit ?').all(limit) as any[];
    for (const r of ticks) {
      const type: ActivityType = r.status === 2 ? 'tick_quarantined' : r.status === 3 ? 'tick_ratified' : 'tick_accepted';
      out.push({ time: r.time, type, tx: r.tx, tickId: r.id, rateBid: r.rate_bid, navBid: r.nav_bid });
    }

    const sent = this.db.prepare('select src_chain, dst_chain, amount, sent_tx as tx, sent_at as time from transfers where sent_at is not null order by sent_at desc limit ?').all(limit) as any[];
    for (const r of sent) {
      out.push({ time: r.time, type: 'bridge_sent', tx: r.tx, srcChain: r.src_chain, dstChain: r.dst_chain, amount: r.amount });
    }

    const arrived = this.db.prepare('select src_chain, dst_chain, received_amount as amount, received_tx as tx, received_at as time from transfers where received_at is not null order by received_at desc limit ?').all(limit) as any[];
    for (const r of arrived) {
      out.push({ time: r.time, type: 'bridge_arrived', tx: r.tx, srcChain: r.src_chain, dstChain: r.dst_chain, amount: r.amount });
    }

    out.sort((a, b) => b.time - a.time);
    return out.slice(0, limit);
  }

  /** One chain's capital. Agent, strategy and every provider are independent reads. */
  private async chainAllocation(c: Chain) {
    const agentAddr = c.manifest.contracts.ChainAgent;
    const strategyAddr = c.manifest.contracts.Strategy;
    const agent = new Contract(agentAddr, CHAIN_AGENT, c.provider);
    const strategy = new Contract(strategyAddr, STRATEGY, c.provider);
    const [idle, shares, addrs, total, healthy] = await Promise.all([
      rpc(() => new Contract(c.entry.usdc, ERC20, c.provider).balanceOf(agentAddr) as Promise<bigint>),
      rpc(() => agent.strategyShares() as Promise<bigint>),
      rpc(() => strategy.getProviders() as Promise<string[]>),
      rpc(() => strategy.totalAssets() as Promise<bigint>),
      rpc(() => strategy.providersHealthy() as Promise<boolean>),
    ]);
    const value: bigint = shares > 0n ? await rpc(() => strategy.convertToAssets(shares) as Promise<bigint>) : 0n;
    const providers = await Promise.all(
      addrs.map(async (p) => {
        const pc = new Contract(p, PROVIDER, c.provider);
        // A provider whose view reverts is reported as zero rather than failing the whole read;
        // `providersHealthy` is what tells a consumer that this happened.
        const [balance, name, cap] = await Promise.all([
          rpc(() => pc.getDepositBalance(strategyAddr, strategyAddr) as Promise<bigint>).catch(() => 0n),
          rpc(() => pc.getIdentifier() as Promise<string>).catch(() => p),
          rpc(() => strategy.getProviderCap(p) as Promise<bigint>).catch(() => 0n),
        ]);
        return {
          address: p,
          identifier: name,
          label: providerLabel(c.entry, c.manifest.contracts, p),
          capBps: Number(cap),
          agentShare: total > 0n ? ((balance * value) / total).toString() : '0',
        };
      }),
    );
    return {
      chainId: Number(c.chainId),
      network: c.key,
      role: c.entry.role,
      agent: agentAddr,
      idle: idle.toString(),
      strategy: strategyAddr,
      strategyValue: value.toString(),
      providersHealthy: healthy,
      providers,
    };
  }

  async allocation() {
    const chains = await Promise.all(this.chains.map((c) => this.chainAllocation(c)));
    const inFlight = this.transfers(500).filter((t) => t.state === 'in_flight');
    return { chains, inFlight };
  }
}

const EPOCH_VAULT_EVENTS = [
  ...EPOCH_VAULT,
  'event RequestCancelled(uint256 indexed requestId)',
  'event DepositClaimed(uint256 indexed requestId, address indexed receiver, uint256 shares)',
  'event RedeemClaimed(uint256 indexed requestId, address indexed receiver, uint256 assets)',
  'event InstantRedeemed(address indexed owner, address indexed receiver, uint64 indexed tickId, uint256 shares, uint256 assets)',
];

/*//////////////////////////////////////////////////////////////
                              SERVER
//////////////////////////////////////////////////////////////*/

export function createServer(ix: Indexer, state: { lastSync: number; lastError: string }): http.Server {
  const cors = process.env.INDEXER_CORS_ORIGIN ?? '*';
  return http.createServer(async (req, res) => {
    const send = (code: number, body: unknown) => {
      res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': cors, 'cache-control': 'no-store' });
      res.end(JSON.stringify(body, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
    };
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { 'access-control-allow-origin': cors, 'access-control-allow-methods': 'GET', 'access-control-allow-headers': 'content-type' });
      return res.end();
    }
    const url = new URL(req.url ?? '/', 'http://x');
    const limit = (d: number, max: number) => Math.min(max, Math.max(1, Number(url.searchParams.get('limit') ?? d) || d));
    try {
      const p = url.pathname;
      if (p === '/health') {
        // A sync counts as late only once it has missed its own cadence by a wide margin. The
        // window used to be a flat five minutes, which made a deliberately slow poll (a gentle
        // RPC budget) report an outage forever.
        const windowMs = Math.max(5 * 60, POLL_SECONDS * 3) * 1000;
        // A single transient RPC failure must not invalidate a fresh cache. Keep reporting the
        // error for diagnostics, and turn unhealthy only when successful syncs are actually stale.
        const healthy = Date.now() - state.lastSync < windowMs;
        return send(healthy ? 200 : 503, { service: SERVICE, healthy, lastSync: new Date(state.lastSync).toISOString(), lastError: state.lastError, indexedTo: ix.lag() });
      }
      if (p === '/v1/vault') return send(200, await ix.vaultSummary());
      if (p === '/v1/instant-remaining') {
        const value = url.searchParams.get('dailyLimit') ?? '';
        if (!/^\d{1,78}$/.test(value)) return send(400, { error: 'dailyLimit must be an unsigned integer' });
        return send(200, { instantRemainingEstimate: ix.instantRemainingEstimate(BigInt(value)) });
      }
      if (p === '/v1/epochs') return send(200, await ix.epochList(limit(20, 100)));
      if (p === '/v1/ticks') return send(200, ix.ticks(limit(200, 2000)));
      if (p === '/v1/transfers') return send(200, ix.transfers(limit(50, 500)));
      if (p === '/v1/activity') return send(200, ix.activity(limit(50, 500)));
      if (p === '/v1/allocation') return send(200, await ix.allocation());
      let m = p.match(/^\/v1\/users\/(0x[0-9a-fA-F]{40})$/);
      if (m && isAddress(m[1])) return send(200, await ix.user(m[1]));
      m = p.match(/^\/v1\/requests\/(\d+)$/);
      if (m) {
        const r = await ix.request(Number(m[1]));
        return r ? send(200, r) : send(404, { error: 'not found' });
      }
      send(404, { error: 'not found' });
    } catch (e) {
      log(SERVICE, 'request failed', { url: req.url, error: String(e) });
      send(500, { error: 'internal error' });
    }
  });
}

async function main() {
  const ix = new Indexer(loadChains(), process.env.INDEXER_DB ?? 'crosschain-indexer.sqlite');
  const state = { lastSync: 0, lastError: '' };
  if (!process.argv.includes('--once')) {
    const port = envNumber('PORT_INDEXER', 8085);
    const host = process.env.INDEXER_HOST ?? '0.0.0.0';
    createServer(ix, state).listen(port, host, () => log(SERVICE, `api on ${host}:${port}`));
  }
  await loop(SERVICE, POLL_SECONDS * 1000, async () => {
    try {
      await ix.sync();
      state.lastSync = Date.now();
      state.lastError = '';
    } catch (e) {
      state.lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  });
  if (process.argv.includes('--once')) console.log(JSON.stringify({ indexedTo: ix.lag() }));
}

if (require.main === module) {
  main().catch((e) => {
    log(SERVICE, 'fatal', { error: String(e) });
    process.exit(1);
  });
}
