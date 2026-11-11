import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { Connection, PublicKey } from '@solana/web3.js';
import { getBytes, hexlify, ZeroAddress, zeroPadValue } from 'ethers';
import { SOLANA, SolanaManifest } from '../../../deploy/crosschain/native-registry';
import type { NativeSpoke } from '../native';
import type { ChainRef, InFlight, Position, TransferIndex } from '../snapshot';
import {
  aliasOf,
  checkpointPda,
  decodeAgent,
  decodeCheckpoint,
  discriminator,
  NativeCheckpoint,
  Reader,
  seedBytes,
} from './codec';

export function validateManifest(m: SolanaManifest): void {
  if (m.family !== 'solana' || m.network !== SOLANA.network) throw new Error('wrong Solana family/network');
  const program = new PublicKey(m.program),
    seed = seedBytes(m.seed);
  const agent = PublicKey.findProgramAddressSync([Buffer.from('agent'), seed], program)[0];
  const idle = PublicKey.findProgramAddressSync([Buffer.from('idle'), agent.toBuffer()], program)[0];
  if (m.agent !== agent.toBase58() || m.idle !== idle.toBase58()) throw new Error('manifest PDA mismatch');
  if (
    !/^0x[0-9a-fA-F]{40}$/.test(m.hubAgent) ||
    !/^0x[0-9a-fA-F]{40}$/.test(m.hubAdapter) ||
    m.hubAgent === ZeroAddress ||
    m.hubAdapter === ZeroAddress
  )
    throw new Error('missing Base endpoints');
  if (
    !Number.isSafeInteger(m.maxCheckpointAgeSeconds) ||
    m.maxCheckpointAgeSeconds < 1 ||
    m.maxCheckpointAgeSeconds > 480
  )
    throw new Error('invalid checkpoint age');
  if (!Array.isArray(m.strategies) || m.strategies.length < 1 || m.strategies.length > 8)
    throw new Error('missing native strategies');
  if (m.localValidator && !m.genesisHash) throw new Error('local validator requires an explicit genesisHash');
  const seen = new Set<string>();
  for (const s of m.strategies) {
    if (s.protocol !== 'kamino-lending' || seen.has(s.reserve))
      throw new Error('unsupported/duplicate native strategy');
    new PublicKey(s.reserve);
    new PublicKey(s.market);
    seen.add(s.reserve);
  }
}

export class SolanaSpoke implements NativeSpoke {
  readonly key = SOLANA.key;
  readonly chainId = SOLANA.accountingId;
  readonly binding: string;
  readonly program: PublicKey;
  readonly agent: PublicKey;
  readonly idle: PublicKey;
  readonly sender: Connection;
  upgradeAuthority?: PublicKey;
  readonly checkpoints: NativeCheckpoint[] = [];
  readonly blockHashes = new Map<number, string>();
  private readonly signatures = new Map<string, string>();
  private verified = false;
  private verifiedAt = 0;
  private pendingSync?: Promise<void>;
  private cache?: DatabaseSync;
  private cacheLoaded = false;

  constructor(readonly connection: Connection, readonly manifest: SolanaManifest, sender: Connection = connection) {
    validateManifest(manifest);
    this.program = new PublicKey(manifest.program);
    this.agent = new PublicKey(manifest.agent);
    this.idle = new PublicKey(manifest.idle);
    this.sender = sender;
    this.binding = `${this.key}:${this.chainId}:${this.program}:${this.agent}:${manifest.network}:${
      manifest.localValidator ? manifest.genesisHash : SOLANA.genesisHash
    }`;
  }
  static fromEnvironment(): SolanaSpoke {
    const file = process.env.CROSSCHAIN_SOLANA_MANIFEST;
    if (!file) throw new Error('CROSSCHAIN_SOLANA_MANIFEST is not set');
    const rpc = process.env.RPC_SOLANA;
    if (!rpc) throw new Error('RPC_SOLANA is not set');
    const createConnection = (url: string) =>
      new Connection(url, {
        commitment: 'finalized',
        disableRetryOnRateLimit: true,
        fetch: (url, init) =>
          fetch(url, { ...init, signal: AbortSignal.timeout(Number(process.env.SOLANA_RPC_TIMEOUT_MS ?? 15_000)) }),
      });
    const read = createConnection(rpc),
      send = process.env.RPC_SEND_SOLANA;
    return new SolanaSpoke(
      read,
      JSON.parse(fs.readFileSync(file, 'utf8')),
      send && send !== rpc ? createConnection(send) : read,
    );
  }
  async state() {
    await this.verify();
    const account = await this.connection.getAccountInfo(this.agent, 'finalized');
    if (!account || !account.owner.equals(this.program)) throw new Error('native agent absent or wrong owner');
    const state = decodeAgent(account.data);
    if (
      !state.seed.equals(seedBytes(this.manifest.seed)) ||
      !state.idle.equals(this.idle) ||
      state.route.chainId !== 8453n ||
      state.route.domain !== 6 ||
      state.route.agent.toLowerCase() !== zeroPadValue(this.manifest.hubAgent, 32).toLowerCase() ||
      state.route.adapter.toLowerCase() !== zeroPadValue(this.manifest.hubAdapter, 32).toLowerCase()
    )
      throw new Error('native agent differs from manifest');
    if (state.strategies.length !== this.manifest.strategies.length)
      throw new Error('native strategy set differs from manifest');
    state.strategies.forEach((s, i) => {
      const m = this.manifest.strategies[i];
      if (s.protocol !== 1 || s.reserve.toBase58() !== m.reserve || s.market.toBase58() !== m.market)
        throw new Error('native strategy binding mismatch');
    });
    return state;
  }
  private async verify(): Promise<void> {
    if (this.verified && Date.now() - this.verifiedAt < 300_000) return;
    const genesis = await this.connection.getGenesisHash();
    if (this.sender !== this.connection && (await this.sender.getGenesisHash()) !== genesis)
      throw new Error('Solana read/send RPC genesis mismatch');
    if (!this.manifest.localValidator && genesis !== SOLANA.genesisHash)
      throw new Error('RPC_SOLANA is not Solana mainnet');
    if (this.manifest.localValidator && genesis !== this.manifest.genesisHash)
      throw new Error('local validator genesis differs from manifest');
    if (
      this.manifest.localValidator &&
      !/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:|\/)/.test(this.connection.rpcEndpoint)
    )
      throw new Error('localValidator requires loopback RPC');
    const program = await this.connection.getAccountInfo(this.program, 'finalized');
    if (!program?.executable) throw new Error('native agent program is not deployed');
    if (!this.manifest.localValidator) {
      const expected = this.manifest.programDataSha256;
      if (!expected || !/^[a-fA-F0-9]{64}$/.test(expected))
        throw new Error('production native manifest requires reviewed programDataSha256');
      const loader = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');
      if (!program.owner.equals(loader) || program.data.length !== 36 || program.data.readUInt32LE() !== 2)
        throw new Error('unsupported native agent program loader');
      const info = await this.connection.getAccountInfo(new PublicKey(program.data.subarray(4, 36)), 'finalized');
      if (!info || !info.owner.equals(loader) || info.data.length < 45 || info.data.readUInt32LE() !== 3)
        throw new Error('native ProgramData unavailable/wrong owner');
      const hash = createHash('sha256').update(info.data.subarray(45)).digest('hex');
      if (hash !== expected.toLowerCase())
        throw new Error('native program bytecode differs from the reviewed manifest');
      if (info.data[12] > 1) throw new Error('invalid native upgrade authority option');
      this.upgradeAuthority = info.data[12] === 1 ? new PublicKey(info.data.subarray(13, 45)) : undefined;
    }
    this.verified = true;
    this.verifiedAt = Date.now();
  }
  async sync(index: TransferIndex): Promise<void> {
    if (this.pendingSync) await this.pendingSync;
    else {
      this.pendingSync = this.readNewCheckpoints();
      try {
        await this.pendingSync;
      } finally {
        this.pendingSync = undefined;
      }
    }
    // Rehydrate each caller's index. Checkpoints are durable on-chain; no local
    // cache can invent a receipt. Immutable PDAs survive operator restarts.
    for (const cp of this.checkpoints) {
      const m = cp.movement;
      if (m.kind === 0) continue;
      const cached = index.sent.get(m.transferId)?.txHash;
      const txHash = m.kind === 1 ? cached || (await this.sourceTransaction(cp)) : '';
      const event = { transferId: m.transferId, chainKey: this.key, block: cp.slot, txHash, amount: m.amount };
      if (m.kind === 1) index.sent.set(m.transferId, { ...event, dstChainId: m.peerChain, minReceive: m.minimum });
      else index.received.set(m.transferId, event);
    }
  }
  private async sourceTransaction(cp: NativeCheckpoint): Promise<string> {
    const cached = this.signatures.get(cp.movement.transferId);
    if (cached) return cached;
    const checkpoint = checkpointPda(this.program, this.agent, cp.sequence);
    const block = await this.connection.getBlock(cp.slot, {
      commitment: 'finalized',
      maxSupportedTransactionVersion: 0,
      rewards: false,
    });
    if (!block) throw new Error('native send block unavailable');
    for (const entry of block.transactions) {
      if (entry.meta?.err) continue;
      const message = entry.transaction.message;
      const keys = message.getAccountKeys({ accountKeysFromLookups: entry.meta?.loadedAddresses });
      for (const ix of message.compiledInstructions) {
        if (
          !keys.get(ix.programIdIndex)?.equals(this.program) ||
          !keys.get(ix.accountKeyIndexes[3])?.equals(checkpoint)
        )
          continue;
        const data = Buffer.from(ix.data);
        if (!data.subarray(0, 8).equals(discriminator('global:execute')) || data[8] !== 3) continue;
        const signature = entry.transaction.signatures[0];
        this.signatures.set(cp.movement.transferId, signature);
        return signature;
      }
    }
    throw new Error('native send checkpoint has no matching successful transaction');
  }
  private async readNewCheckpoints(): Promise<void> {
    await this.verify();
    const state = await this.state();
    if (!this.cacheLoaded) {
      const file = process.env.SOLANA_CHECKPOINT_DB;
      if (file) {
        fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
        this.cache = new DatabaseSync(file);
        this.cache.exec(
          'PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS native_checkpoints(binding TEXT NOT NULL,sequence INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(binding,sequence))',
        );
        for (const row of this.cache
          .prepare('SELECT data FROM native_checkpoints WHERE binding=? ORDER BY sequence')
          .all(this.binding)) {
          const data = Buffer.from(row.data as Uint8Array),
            cp = decodeCheckpoint(data);
          this.validateCheckpoint(cp, this.checkpoints.length);
          this.checkpoints.push(cp);
        }
      }
      this.cacheLoaded = true;
    }
    if (BigInt(this.checkpoints.length) > state.sequence)
      throw new Error('native checkpoint cache is ahead of finalized chain state');
    if (state.sequence > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('native history exceeds safe sequence range');
    for (let first = this.checkpoints.length; first < Number(state.sequence); first += 64) {
      const count = Math.min(64, Number(state.sequence) - first);
      const keys = Array.from({ length: count }, (_, n) => checkpointPda(this.program, this.agent, BigInt(first + n)));
      const infos = await this.connection.getMultipleAccountsInfo(keys, 'finalized');
      for (let n = 0; n < count; n++) {
        const info = infos[n];
        if (!info || !info.owner.equals(this.program)) throw new Error(`missing native checkpoint ${first + n}`);
        const cp = decodeCheckpoint(info.data);
        this.validateCheckpoint(cp, first + n);
        this.cache
          ?.prepare('INSERT OR IGNORE INTO native_checkpoints(binding,sequence,data) VALUES(?,?,?)')
          .run(this.binding, Number(cp.sequence), info.data);
        this.checkpoints.push(cp);
      }
    }
  }
  private validateCheckpoint(cp: NativeCheckpoint, sequence: number) {
    if (!cp.agent.equals(this.agent) || cp.sequence !== BigInt(sequence)) throw new Error('invalid checkpoint binding');
    const prior = this.checkpoints.at(-1);
    if (prior && (cp.slot < prior.slot || cp.timestamp < prior.timestamp))
      throw new Error('native history is not monotonic');
    if (
      cp.positions.length > this.manifest.strategies.length ||
      cp.positions.some((p, i) => p.reserve.toBase58() !== this.manifest.strategies[i].reserve)
    )
      throw new Error('checkpoint strategies differ from manifest');
    if (cp.movement.kind && cp.movement.peerChain !== 8453n) throw new Error('unknown native peer');
  }
  checkpointAt(slot: number): NativeCheckpoint {
    const cp = this.checkpoints.findLast((x) => x.slot <= slot);
    if (!cp) throw new Error(`no native checkpoint at slot ${slot}`);
    return cp;
  }
  async referenceAt(timestamp: number, ceiling = Number.MAX_SAFE_INTEGER): Promise<ChainRef> {
    const cp = this.checkpoints.findLast((x) => x.timestamp <= timestamp && x.slot <= ceiling);
    if (!cp || timestamp - cp.timestamp > this.manifest.maxCheckpointAgeSeconds)
      throw new Error('Solana checkpoint stale/missing; refresh before NAV');
    return { chainId: this.chainId, blockNumber: BigInt(cp.slot), blockHash: await this.referenceHash(cp.slot) };
  }
  async referenceHash(slot: number): Promise<string> {
    let hash = this.blockHashes.get(slot);
    if (!hash) {
      const block = await this.connection.getBlock(slot, {
        commitment: 'finalized',
        transactionDetails: 'none',
        rewards: false,
        maxSupportedTransactionVersion: 0,
      });
      if (!block) throw new Error(`finalized native block ${slot} unavailable`);
      hash = hexlify(new PublicKey(block.blockhash).toBytes());
      this.blockHashes.set(slot, hash);
    }
    return hash;
  }
  async positionsAt(slot: number): Promise<Position[]> {
    const cp = this.checkpointAt(slot),
      holder = aliasOf(this.agent);
    // A cut may roll below a later checkpoint, but cannot price a movement using
    // an earlier observation from the same slot; latest sequence wins per slot.
    const out: Position[] = [
      {
        chainId: this.chainId,
        holder,
        strategy: ZeroAddress,
        kind: 0,
        units: cp.idle,
        valueBid: cp.idle,
        valueOffer: cp.idle,
      },
    ];
    for (const p of cp.positions) {
      if (p.units === 0n) continue;
      // `observationFailed` means the reserve could not be refreshed or valued in that
      // slot, so `value` is unknown rather than zero. The program tolerates a failed
      // observation on Receive and Observe so a dead reserve cannot strand an inbound
      // transfer, but pricing the position at zero here would under-report NAV and let
      // deposits and redemptions clear against a rate the position does not support.
      // Fail the whole cut instead: an unpriceable spoke halts NAV rather than misprices it.
      if (p.observationFailed)
        throw new Error(
          `native position ${p.reserve.toBase58()} (sequence ${cp.sequence}, slot ${cp.slot}) has no observation; NAV cannot be determined`,
        );
      out.push({
        chainId: this.chainId,
        holder,
        strategy: aliasOf(p.reserve),
        kind: 1,
        units: p.units,
        valueBid: p.value,
        valueOffer: p.value,
      });
    }
    return out.filter((p) => p.units !== 0n);
  }
  async sentAt(transferId: string, slot: number): Promise<InFlight> {
    const cp = this.checkpoints.find(
      (x) => x.slot <= slot && x.movement.kind === 1 && x.movement.transferId === transferId,
    );
    if (!cp) throw new Error('native send not found in cut');
    const loss = PublicKey.findProgramAddressSync(
      [Buffer.from('loss'), this.agent.toBuffer(), Buffer.from(getBytes(transferId))],
      this.program,
    )[0];
    const info = await this.connection.getAccountInfo(loss, 'finalized');
    let writtenDown = 0n;
    if (info) {
      if (!info.owner.equals(this.program)) throw new Error('native loss account owner mismatch');
      const r = new Reader(info.data);
      if (
        !r.take(8).equals(discriminator('account:Loss')) ||
        !r.key().equals(this.agent) ||
        hexlify(r.take(32)) !== transferId
      )
        throw new Error('native loss account binding mismatch');
      const total = r.u64(),
        count = r.u32();
      if (count > 32) throw new Error('native loss history malformed');
      let sum = 0n;
      for (let i = 0; i < count; i++) {
        const at = r.u64(),
          amount = r.u64();
        r.take(32);
        sum += amount;
        if (at <= BigInt(slot)) writtenDown += amount;
      }
      if (sum !== total || total > cp.movement.amount) throw new Error('native loss exceeds send amount');
    }
    return {
      transferId,
      srcChainId: this.chainId,
      dstChainId: cp.movement.peerChain,
      sentAt: BigInt(cp.timestamp),
      amountSent: cp.movement.amount,
      minReceive: cp.movement.minimum,
      writtenDown,
    };
  }
}
