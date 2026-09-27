/**
 * NAV snapshot engine: builds the canonical snapshot of docs/nav-reproduction.md,
 * encodes and hashes it exactly like `keccak256(abi.encode(snapshot))`, decodes
 * committed snapshots from `commitTick` calldata, and independently re-derives a
 * committed Tick to detect updater faults.
 */
import { AbiCoder, Contract, Interface, keccak256, Provider } from 'ethers';
import { CHAIN_AGENT, EPOCH_VAULT, ERC20, SNAPSHOT_TUPLE, STRATEGY, TICK_ACCOUNTANT } from './abi';
import { Chain, hubOf } from './config';
import { blockAtOrBefore, scanEvents } from './util';

export const KIND_IDLE = 0;
export const KIND_STRATEGY_SHARES = 1;
const WAD = 10n ** 18n;

export interface ChainRef {
  chainId: bigint;
  blockNumber: bigint;
  blockHash: string;
}
export interface Position {
  chainId: bigint;
  holder: string;
  strategy: string;
  kind: number;
  units: bigint;
  valueBid: bigint;
  valueOffer: bigint;
}
export interface InFlight {
  transferId: string;
  srcChainId: bigint;
  dstChainId: bigint;
  sentAt: bigint;
  amountSent: bigint;
  minReceive: bigint;
  writtenDown: bigint;
}
export interface Snapshot {
  version: number;
  tickId: bigint;
  referenceTime: bigint;
  chains: ChainRef[];
  positions: Position[];
  inFlight: InFlight[];
  hubCash: bigint;
  pendingDeposits: bigint;
  liabilities: bigint;
  totalShares: bigint;
}

export interface Totals {
  navBid: bigint;
  navOffer: bigint;
  inFlight: bigint;
  overdueInFlight: bigint;
  grossBid: bigint;
  grossOffer: bigint;
}

const coder = AbiCoder.defaultAbiCoder();

export function encodeSnapshot(s: Snapshot): string {
  return coder.encode([SNAPSHOT_TUPLE], [s]);
}

export function hashSnapshot(s: Snapshot): string {
  return keccak256(encodeSnapshot(s));
}

/** Mirrors NavSnapshot.totals + the gross rate derivation in TickAccountant. */
export function totals(s: Snapshot, maxTransit: bigint): Totals {
  let bid = s.hubCash;
  let offer = s.hubCash;
  for (const p of s.positions) {
    bid += p.valueBid;
    offer += p.valueOffer;
  }
  let inFlight = 0n;
  let overdue = 0n;
  for (const f of s.inFlight) {
    const o = f.amountSent - f.writtenDown;
    const b = f.minReceive < o ? f.minReceive : o;
    bid += b;
    offer += o;
    inFlight += o;
    if (s.referenceTime > f.sentAt && s.referenceTime - f.sentAt > maxTransit) overdue += o;
  }
  const ded = s.pendingDeposits + s.liabilities;
  const navBid = bid - ded;
  const navOffer = offer - ded;
  return {
    navBid,
    navOffer,
    inFlight,
    overdueInFlight: overdue,
    grossBid: s.totalShares === 0n ? 0n : (navBid * WAD) / s.totalShares,
    grossOffer: s.totalShares === 0n ? 0n : (navOffer * WAD) / s.totalShares,
  };
}

export function positionKey(p: Pick<Position, 'chainId' | 'holder' | 'strategy' | 'kind'>): string {
  return `${p.chainId}:${p.holder.toLowerCase()}:${p.strategy.toLowerCase()}:${p.kind}`;
}

function cmpAddr(a: string, b: string): number {
  const x = BigInt(a);
  const y = BigInt(b);
  return x < y ? -1 : x > y ? 1 : 0;
}

export function sortPositions(ps: Position[]): Position[] {
  return [...ps].sort((a, b) => {
    if (a.chainId !== b.chainId) return a.chainId < b.chainId ? -1 : 1;
    const h = cmpAddr(a.holder, b.holder);
    if (h) return h;
    const s = cmpAddr(a.strategy, b.strategy);
    if (s) return s;
    return a.kind - b.kind;
  });
}

/*//////////////////////////////////////////////////////////////
                       TRANSFER EVENT INDEX
//////////////////////////////////////////////////////////////*/

export interface TransferEvent {
  transferId: string;
  chainKey: string;
  block: number;
  txHash: string;
  amount: bigint;
}

/**
 * Incremental index of BridgeOut / BridgeIn per agent, from each manifest's
 * start block. A transfer is keyed by id; `sent` is on the source chain,
 * `received` on the destination chain.
 */
export class TransferIndex {
  readonly sent = new Map<string, TransferEvent & { dstChainId: bigint; minReceive: bigint }>();
  readonly received = new Map<string, TransferEvent>();
  private scanned = new Map<string, number>();

  async sync(chains: Chain[], upTo?: Map<string, number>): Promise<void> {
    for (const c of chains) {
      const agent = new Contract(c.manifest.contracts.ChainAgent, CHAIN_AGENT, c.provider);
      const head = upTo?.get(c.key) ?? (await c.provider.getBlockNumber());
      const from = (this.scanned.get(c.key) ?? c.manifest.startBlock - 1) + 1;
      if (from > head) continue;
      for (const e of await scanEvents(agent, 'BridgeOut', from, head)) {
        this.sent.set(e.args.transferId, {
          transferId: e.args.transferId,
          chainKey: c.key,
          block: e.blockNumber,
          txHash: e.transactionHash,
          amount: e.args.amount,
          dstChainId: e.args.dstChainId,
          minReceive: e.args.minReceive,
        });
      }
      for (const e of await scanEvents(agent, 'BridgeIn', from, head)) {
        this.received.set(e.args.transferId, {
          transferId: e.args.transferId,
          chainKey: c.key,
          block: e.blockNumber,
          txHash: e.transactionHash,
          amount: e.args.amount,
        });
      }
      this.scanned.set(c.key, head);
    }
  }
}

/**
 * Consistent cut (docs/nav-reproduction.md step 2): advance a source reference
 * block until every receipt inside the cut has its send inside the cut.
 * Pure function over the index; returns the adjusted refs.
 */
export function consistentCut(refs: Map<string, number>, index: TransferIndex): Map<string, number> {
  const out = new Map(refs);
  for (let changed = true; changed; ) {
    changed = false;
    for (const [id, r] of index.received) {
      if (r.block > (out.get(r.chainKey) ?? -1)) continue;
      const s = index.sent.get(id);
      if (!s) throw new Error(`receipt ${id} on ${r.chainKey} has no BridgeOut in the index`);
      if (s.block > (out.get(s.chainKey) ?? -1)) {
        out.set(s.chainKey, s.block);
        changed = true;
      }
    }
  }
  return out;
}

/*//////////////////////////////////////////////////////////////
                             BUILDER
//////////////////////////////////////////////////////////////*/

export interface Built {
  snapshot: Snapshot;
  hubCheckpointIndex: bigint;
  refs: Map<string, number>;
  totals: Totals;
  unhealthy: string[];
}

async function positionsAt(c: Chain, block: number, prevOffers: Map<string, bigint>, unhealthy: string[]): Promise<Position[]> {
  const agentAddr = c.manifest.contracts.ChainAgent;
  const usdc = new Contract(c.entry.usdc, ERC20, c.provider);
  const agent = new Contract(agentAddr, CHAIN_AGENT, c.provider);
  const tag = { blockTag: block };
  const out: Position[] = [];
  const idle: bigint = await usdc.balanceOf(agentAddr, tag);
  if (idle > 0n) {
    out.push({ chainId: c.chainId, holder: agentAddr, strategy: '0x0000000000000000000000000000000000000000', kind: KIND_IDLE, units: idle, valueBid: idle, valueOffer: idle });
  }
  const strategyAddr: string = await agent.strategy(tag);
  const strategy = new Contract(strategyAddr, STRATEGY, c.provider);
  const shares: bigint = await strategy.balanceOf(agentAddr, tag);
  if (shares > 0n) {
    const value: bigint = await strategy.convertToAssets(shares, tag);
    const healthy: boolean = await strategy.providersHealthy(tag);
    const pos: Position = { chainId: c.chainId, holder: agentAddr, strategy: strategyAddr, kind: KIND_STRATEGY_SHARES, units: shares, valueBid: value, valueOffer: value };
    if (!healthy) {
      // docs/nav-reproduction.md: offer = max(bid, previous accepted offer of the same position)
      const prev = prevOffers.get(positionKey(pos)) ?? 0n;
      if (prev > pos.valueOffer) pos.valueOffer = prev;
      unhealthy.push(`${c.key}:${strategyAddr}`);
    }
    out.push(pos);
  }
  return out;
}

async function inFlightAt(chains: Chain[], refs: Map<string, number>, index: TransferIndex): Promise<InFlight[]> {
  const byKey = new Map(chains.map((c) => [c.key, c]));
  const out: InFlight[] = [];
  for (const [id, s] of index.sent) {
    if (s.block > refs.get(s.chainKey)!) continue;
    const r = index.received.get(id);
    if (r && r.block <= refs.get(r.chainKey)!) continue;
    const src = byKey.get(s.chainKey)!;
    const agent = new Contract(src.manifest.contracts.ChainAgent, CHAIN_AGENT, src.provider);
    const rec = await agent.getSent(id, { blockTag: refs.get(s.chainKey)! });
    out.push({
      transferId: id,
      srcChainId: src.chainId,
      dstChainId: BigInt(rec.dstChainId),
      sentAt: BigInt(rec.sentAt),
      amountSent: BigInt(rec.amount),
      minReceive: BigInt(rec.minReceive),
      writtenDown: BigInt(rec.writtenDown),
    });
  }
  return out.sort((a, b) => (BigInt(a.transferId) < BigInt(b.transferId) ? -1 : 1));
}

async function hubFieldsAt(hub: Chain, block: number) {
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  const n: bigint = await vault.checkpointCount({ blockTag: block });
  const idx = n - 1n;
  const cp = await vault.checkpointAt(idx, { blockTag: block });
  return { idx, cash: BigInt(cp.cash), pendingDeposits: BigInt(cp.pendingDeposits), liabilities: BigInt(cp.liabilities), totalShares: BigInt(cp.totalSupply) };
}

async function chainRefs(chains: Chain[], refs: Map<string, number>): Promise<ChainRef[]> {
  const out: ChainRef[] = [];
  for (const c of [...chains].sort((a, b) => (a.chainId < b.chainId ? -1 : 1))) {
    const b = await c.provider.getBlock(refs.get(c.key)!);
    out.push({ chainId: c.chainId, blockNumber: BigInt(b!.number), blockHash: b!.hash! });
  }
  return out;
}

/**
 * Builds the next snapshot. Hub reference = hub head - confirmations (it must
 * stay within 256 blocks of the commit); spokes = last confirmed block at or
 * before the hub reference time; then the consistent-cut fixpoint.
 */
export async function buildSnapshot(allChains: Chain[], index: TransferIndex, prevOffers: Map<string, bigint>): Promise<Built> {
  const hub = hubOf(allChains);
  // the chain set is the accountant's, not the registry's: while a new network's
  // setChains is still queued in the Timelock, snapshots must not include it
  const onChain: bigint[] = (await new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider).chainIds()).map((x: bigint) => BigInt(x));
  const chains = allChains.filter((c) => onChain.includes(c.chainId));
  const missing = onChain.filter((id) => !chains.some((c) => c.chainId === id));
  if (missing.length) throw new Error(`accountant tracks chains not configured here: ${missing.join(',')}`);
  const heads = new Map<string, number>();
  for (const c of chains) heads.set(c.key, await c.provider.getBlockNumber());

  const conf = (c: Chain) => Number(process.env[`CONFIRMATIONS_${c.key.toUpperCase()}`] ?? c.entry.confirmations);
  const refs = new Map<string, number>();
  const hubRef = heads.get(hub.key)! - conf(hub);
  refs.set(hub.key, hubRef);
  const t = (await hub.provider.getBlock(hubRef))!.timestamp;
  for (const c of chains) {
    if (c === hub) continue;
    const confirmed = heads.get(c.key)! - conf(c);
    const lo = c.manifest.startBlock;
    const ts = (await c.provider.getBlock(lo))!.timestamp;
    refs.set(c.key, ts > t ? lo : await blockAtOrBefore(c.provider, t, lo, confirmed));
  }

  await index.sync(chains, heads);
  const cut = consistentCut(refs, index);
  return assemble(chains, index, cut, prevOffers);
}

async function assemble(chains: Chain[], index: TransferIndex, refs: Map<string, number>, prevOffers: Map<string, bigint>, tickIdOverride?: bigint): Promise<Built> {
  const hub = hubOf(chains);
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const unhealthy: string[] = [];
  let positions: Position[] = [];
  for (const c of chains) positions = positions.concat(await positionsAt(c, refs.get(c.key)!, prevOffers, unhealthy));
  const hubBlock = refs.get(hub.key)!;
  const hubFields = await hubFieldsAt(hub, hubBlock);
  const tickId = tickIdOverride ?? BigInt(await accountant.lastTickId()) + 1n;
  const snapshot: Snapshot = {
    version: 1,
    tickId,
    referenceTime: BigInt((await hub.provider.getBlock(hubBlock))!.timestamp),
    chains: await chainRefs(chains, refs),
    positions: sortPositions(positions),
    inFlight: await inFlightAt(chains, refs, index),
    hubCash: hubFields.cash,
    pendingDeposits: hubFields.pendingDeposits,
    liabilities: hubFields.liabilities,
    totalShares: hubFields.totalShares,
  };
  const cfg = await accountant.config();
  return { snapshot, hubCheckpointIndex: hubFields.idx, refs, totals: totals(snapshot, BigInt(cfg.maxTransit)), unhealthy };
}

/*//////////////////////////////////////////////////////////////
                    COMMITTED SNAPSHOTS AND VERIFY
//////////////////////////////////////////////////////////////*/

const accountantIface = new Interface(TICK_ACCOUNTANT);

function toSnapshot(r: any): Snapshot {
  return {
    version: Number(r.version),
    tickId: BigInt(r.tickId),
    referenceTime: BigInt(r.referenceTime),
    chains: r.chains.map((c: any) => ({ chainId: BigInt(c.chainId), blockNumber: BigInt(c.blockNumber), blockHash: c.blockHash })),
    positions: r.positions.map((p: any) => ({ chainId: BigInt(p.chainId), holder: p.holder, strategy: p.strategy, kind: Number(p.kind), units: BigInt(p.units), valueBid: BigInt(p.valueBid), valueOffer: BigInt(p.valueOffer) })),
    inFlight: r.inFlight.map((f: any) => ({ transferId: f.transferId, srcChainId: BigInt(f.srcChainId), dstChainId: BigInt(f.dstChainId), sentAt: BigInt(f.sentAt), amountSent: BigInt(f.amountSent), minReceive: BigInt(f.minReceive), writtenDown: BigInt(f.writtenDown) })),
    hubCash: BigInt(r.hubCash),
    pendingDeposits: BigInt(r.pendingDeposits),
    liabilities: BigInt(r.liabilities),
    totalShares: BigInt(r.totalShares),
  };
}

/** Finds and decodes the snapshot committed for `tickId` (from the commitTick calldata). */
export async function committedSnapshot(hub: Chain, tickId: bigint): Promise<{ snapshot: Snapshot; txHash: string; block: number } | undefined> {
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const tick = await accountant.getTick(tickId);
  if (Number(tick.status) === 0 || tickId === 0n) return undefined;
  // the commit happened a few blocks after the hub reference block
  const from = Number(tick.hubBlock);
  const to = from + 300;
  const logs = await accountant.queryFilter(accountant.filters.TickCommitted(tickId), from, to);
  if (logs.length === 0) throw new Error(`TickCommitted(${tickId}) not found in [${from}, ${to}]`);
  const tx = await hub.provider.getTransaction(logs[0].transactionHash);
  const parsed = accountantIface.parseTransaction({ data: tx!.data });
  if (!parsed || parsed.name !== 'commitTick') {
    throw new Error(`tick ${tickId} was not committed by a direct commitTick call (tx ${tx!.hash}); use a trace-capable RPC`);
  }
  return { snapshot: toSnapshot(parsed.args[0]), txHash: tx!.hash, block: logs[0].blockNumber };
}

export function offersOf(s: Snapshot): Map<string, bigint> {
  return new Map(s.positions.map((p) => [positionKey(p), p.valueOffer]));
}

export interface VerifyResult {
  tickId: bigint;
  ok: boolean;
  mismatches: string[];
}

/**
 * Independent re-derivation of a committed Tick: recompute every field from the
 * chains at the snapshot's own reference blocks and compare. Any difference is
 * an updater fault (docs/nav-reproduction.md §3).
 */
export async function verifyTick(allChains: Chain[], index: TransferIndex, tickId: bigint): Promise<VerifyResult> {
  let chains = allChains;
  const hub = hubOf(chains);
  const committed = await committedSnapshot(hub, tickId);
  if (!committed) return { tickId, ok: true, mismatches: [] };
  const s = committed.snapshot;
  const mismatches: string[] = [];

  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const tick = await accountant.getTick(tickId);
  if (hashSnapshot(s) !== tick.navHash) mismatches.push('navHash does not match the committed calldata');

  const refs = new Map<string, number>();
  for (const r of s.chains) {
    if (!chains.some((c) => c.chainId === r.chainId)) mismatches.push(`snapshot chain ${r.chainId} is not configured here`);
  }
  chains = chains.filter((c) => s.chains.some((r) => r.chainId === c.chainId));
  for (const c of chains) {
    const ref = s.chains.find((r) => r.chainId === c.chainId)!;
    const b = await c.provider.getBlock(Number(ref.blockNumber));
    if (!b || b.hash !== ref.blockHash) mismatches.push(`${c.key}: block ${ref.blockNumber} hash mismatch (reorg or wrong reference)`);
    refs.set(c.key, Number(ref.blockNumber));
  }
  if (mismatches.length) return { tickId, ok: false, mismatches };

  await index.sync(chains);
  const fix = consistentCut(refs, index);
  for (const [k, v] of fix) if (v !== refs.get(k)) mismatches.push(`${k}: inconsistent cut, a receipt inside the cut has its send after block ${refs.get(k)}`);

  // previous accepted snapshot for the unhealthy-offer rule
  let prevOffers = new Map<string, bigint>();
  for (let id = tickId - 1n; id > 0n; id--) {
    const t = await accountant.getTick(id);
    if (Number(t.status) === 1 || Number(t.status) === 3) {
      const prev = await committedSnapshot(hub, id);
      if (prev) prevOffers = offersOf(prev.snapshot);
      break;
    }
  }

  const rebuilt = (await assemble(chains, index, refs, prevOffers, s.tickId)).snapshot;
  if (rebuilt.referenceTime !== s.referenceTime) {
    mismatches.push(`referenceTime ${s.referenceTime} is not the hub reference block's timestamp ${rebuilt.referenceTime}`);
  }
  const fields: (keyof Snapshot)[] = ['hubCash', 'pendingDeposits', 'liabilities', 'totalShares'];
  for (const f of fields) if (rebuilt[f] !== s[f]) mismatches.push(`${String(f)}: committed ${s[f]} vs derived ${rebuilt[f]}`);
  const want = new Map(rebuilt.positions.map((p) => [positionKey(p), p]));
  const got = new Map(s.positions.map((p) => [positionKey(p), p]));
  for (const [k, p] of want) {
    const q = got.get(k);
    if (!q) mismatches.push(`position ${k} missing (value ${p.valueBid})`);
    else if (q.units !== p.units || q.valueBid !== p.valueBid || q.valueOffer !== p.valueOffer) {
      mismatches.push(`position ${k}: committed units/bid/offer ${q.units}/${q.valueBid}/${q.valueOffer} vs derived ${p.units}/${p.valueBid}/${p.valueOffer}`);
    }
  }
  for (const k of got.keys()) if (!want.has(k)) mismatches.push(`position ${k} not held on-chain`);
  const wantF = new Map(rebuilt.inFlight.map((f) => [f.transferId, f]));
  const gotF = new Map(s.inFlight.map((f) => [f.transferId, f]));
  for (const [id, f] of wantF) {
    const g = gotF.get(id);
    if (!g) mismatches.push(`in-flight ${id} missing`);
    else if (g.amountSent !== f.amountSent || g.minReceive !== f.minReceive || g.writtenDown !== f.writtenDown || g.sentAt !== f.sentAt) mismatches.push(`in-flight ${id} fields differ`);
  }
  for (const id of gotF.keys()) if (!wantF.has(id)) mismatches.push(`in-flight ${id} not in flight at the cut`);
  if (!mismatches.length && hashSnapshot(rebuilt) !== tick.navHash) mismatches.push('re-derived snapshot hashes differently');
  return { tickId, ok: mismatches.length === 0, mismatches };
}

export async function latestBlockTimestamp(p: Provider): Promise<number> {
  return (await p.getBlock('latest'))!.timestamp;
}
