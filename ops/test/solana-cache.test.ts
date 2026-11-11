/**
 * The SQLite checkpoint cache is a trusted NAV input: `SolanaSpoke.positionsAt`
 * returns its amounts and the hub prices deposits and redemptions with the
 * resulting NAV hash. These tests cover the two protections that keep a rewritten
 * cache file from pricing anything - owner-only permissions, and re-reading the
 * newest rows from chain before believing them.
 *
 * Real SBF execution lives in test/solana-sbf.e2e.ts; this file needs no
 * validator, only an RPC double that serves the accounts a spoke reads.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Connection, PublicKey } from '@solana/web3.js';
import { SOLANA, SolanaManifest } from '../../deploy/crosschain/native-registry';
import { checkpointPda, decodeCheckpoint, discriminator, u64 } from '../src/solana/codec';
import { SolanaSpoke } from '../src/solana/spoke';
import { TransferIndex } from '../src/snapshot';

const key = (n: number) => new PublicKey(Buffer.alloc(32, n));
const program = key(9),
  seed = Buffer.alloc(32, 10),
  reserve = key(1),
  market = key(2);
const agent = PublicKey.findProgramAddressSync([Buffer.from('agent'), seed], program)[0];
const idle = PublicKey.findProgramAddressSync([Buffer.from('idle'), agent.toBuffer()], program)[0];
const manifest: SolanaManifest = {
  family: 'solana',
  network: SOLANA.network,
  program: program.toBase58(),
  seed: `0x${seed.toString('hex')}`,
  agent: agent.toBase58(),
  idle: idle.toBase58(),
  hubAdapter: `0x${'11'.repeat(20)}`,
  hubAgent: `0x${'22'.repeat(20)}`,
  maxCheckpointAgeSeconds: 120,
  // a local validator manifest, so verify() accepts a loopback RPC and skips the
  // mainnet program-digest check
  localValidator: true,
  genesisHash: 'thesauros-solana-cache-test-genesis',
  strategies: [{ protocol: 'kamino-lending', reserve: reserve.toBase58(), market: market.toBase58() }],
};

/** Agent account as the program writes it (ops/src/solana/codec.ts decodeAgent). */
function agentBlob(sequence: bigint) {
  const word = (hex: string) => Buffer.concat([Buffer.alloc(12), Buffer.from(hex, 'hex')]);
  const u16 = (n: number) => Buffer.from([n & 0xff, (n >> 8) & 0xff]);
  const i64 = (n: bigint) => {
    const b = Buffer.alloc(8);
    b.writeBigInt64LE(n);
    return b;
  };
  return Buffer.concat([
    discriminator('account:Agent'),
    seed,
    Buffer.from([255]),
    key(20).toBuffer(), // governance
    key(21).toBuffer(), // executor
    key(22).toBuffer(), // guardian
    idle.toBuffer(),
    Buffer.from([0]), // unpaused
    u64(sequence),
    u64(8453n), // route: Base
    Buffer.from([6, 0, 0, 0]), // route: CCTP domain 6
    word('22'.repeat(20)), // route.agent == manifest.hubAgent
    word('11'.repeat(20)), // route.adapter == manifest.hubAdapter
    key(30).toBuffer(), // route.mint
    key(31).toBuffer(), // route.tokenMessenger
    u64(1_000_000_000n),
    u64(10_000_000_000n),
    u64(1_000_000n),
    u16(10),
    u64(0n), // bucket level
    i64(0n), // bucket updated at
    Buffer.from([1, 0, 0, 0]), // one strategy
    Buffer.from([1]), // protocol: kamino-lending
    reserve.toBuffer(),
    market.toBuffer(),
    key(3).toBuffer(),
    key(4).toBuffer(),
    key(5).toBuffer(),
    key(6).toBuffer(),
    key(7).toBuffer(),
    key(7).toBuffer(),
    key(7).toBuffer(),
    key(7).toBuffer(),
    u64(10_000_000n),
  ]);
}

/** One checkpoint with a single position; `idle` is the amount NAV would price. */
function checkpoint(sequence: bigint, slot: bigint, time: bigint, idleValue: bigint) {
  return Buffer.concat([
    discriminator('account:Checkpoint'),
    agent.toBuffer(),
    u64(sequence),
    u64(slot),
    u64(time),
    u64(idleValue),
    Buffer.from([1, 0, 0, 0]),
    reserve.toBuffer(),
    u64(5_000_000n),
    u64(6_000_000n),
    Buffer.from([0]), // no movement: keeps the RPC double to account reads
    Buffer.alloc(32),
    u64(8453n),
    u64(0n),
    u64(0n),
  ]);
}

/** Ten finalized checkpoints, idle one micro-unit apart, ten slots apart. */
const history = Array.from({ length: 10 }, (_, n) =>
  checkpoint(BigInt(n), BigInt(100 + n * 10), BigInt(1_800_000_000 + n * 10), BigInt(1_000_000 + n)),
);

function rpc(checkpoints: Buffer[]) {
  const byPda = new Map<string, Buffer>();
  checkpoints.forEach((data, n) => byPda.set(checkpointPda(program, agent, BigInt(n)).toBase58(), data));
  return {
    rpcEndpoint: 'http://127.0.0.1:8899',
    getGenesisHash: async () => manifest.genesisHash,
    getAccountInfo: async (pubkey: PublicKey) => {
      if (pubkey.equals(program)) return { executable: true, owner: program, data: Buffer.alloc(36) };
      if (pubkey.equals(agent)) return { owner: program, data: agentBlob(BigInt(checkpoints.length)) };
      return null;
    },
    getMultipleAccountsInfo: async (keys: PublicKey[]) =>
      keys.map((k) => {
        const data = byPda.get(k.toBase58());
        return data ? { owner: program, data } : null;
      }),
  } as unknown as Connection;
}

/** Run `body` with SOLANA_CHECKPOINT_DB pointed at a fresh file. */
async function withCache<T>(body: (file: string) => Promise<T>): Promise<T> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'thesauros-solana-cache-')),
    file = path.join(dir, 'nested', 'checkpoints.sqlite'),
    saved = process.env.SOLANA_CHECKPOINT_DB;
  process.env.SOLANA_CHECKPOINT_DB = file;
  try {
    return await body(file);
  } finally {
    if (saved === undefined) delete process.env.SOLANA_CHECKPOINT_DB;
    else process.env.SOLANA_CHECKPOINT_DB = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Rewrite one cached row the way an attacker with write access to /data would. */
function tamper(file: string, binding: string, sequence: number, blob: Buffer) {
  const db = new DatabaseSync(file);
  db.exec('PRAGMA busy_timeout=5000');
  db.prepare('UPDATE native_checkpoints SET data=? WHERE binding=? AND sequence=?').run(blob, binding, sequence);
  db.close();
}

function cachedBlob(file: string, binding: string, sequence: number): Buffer {
  const db = new DatabaseSync(file);
  const row = db.prepare('SELECT data FROM native_checkpoints WHERE binding=? AND sequence=?').get(binding, sequence) as
    | { data: Uint8Array }
    | undefined;
  db.close();
  if (!row) throw new Error(`no cached checkpoint ${sequence}`);
  return Buffer.from(row.data);
}

const IDLE_OFFSET = 8 + 32 + 8 + 8 + 8; // discriminator, agent, sequence, slot, timestamp
const SLOT_OFFSET = 8 + 32 + 8;

/** An amount edit keeps the discriminator, binding, sequence and monotonicity. */
function withIdle(blob: Buffer, idleValue: bigint) {
  const copy = Buffer.from(blob);
  copy.writeBigUInt64LE(idleValue, IDLE_OFFSET);
  return copy;
}

test('the checkpoint cache is owner-only, and an existing world-readable file is tightened', async () => {
  await withCache(async (file) => {
    const spoke = new SolanaSpoke(rpc(history), manifest);
    await spoke.sync(new TransferIndex());
    assert.equal(spoke.checkpoints.length, 10);
    assert.equal(spoke.binding.startsWith('solana:'), true);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600, 'cache file must not be group/world readable');
    assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700, 'cache directory must not be world writable');
    // WAL journaling keeps the same rows in sidecar files SQLite creates itself
    for (const suffix of ['-wal', '-shm'])
      if (fs.existsSync(file + suffix))
        assert.equal(fs.statSync(file + suffix).mode & 0o777, 0o600, `${suffix} sidecar must be owner-only`);

    // an upgrade from the previous 0644 file is fixed in place, not left behind
    for (const suffix of ['', '-wal', '-shm']) if (fs.existsSync(file + suffix)) fs.chmodSync(file + suffix, 0o644);
    const upgraded = new SolanaSpoke(rpc(history), manifest);
    await upgraded.sync(new TransferIndex());
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    for (const suffix of ['', '-wal', '-shm'])
      if (fs.existsSync(file + suffix))
        assert.equal(fs.statSync(file + suffix).mode & 0o777, 0o600, `${suffix} sidecar must be owner-only`);
    assert.equal(upgraded.checkpoints.length, 10);
  });
});

test('a cached amount the chain disagrees with is discarded and re-read', async () => {
  await withCache(async (file) => {
    const first = new SolanaSpoke(rpc(history), manifest);
    await first.sync(new TransferIndex());
    const binding = first.binding;
    tamper(file, binding, 9, withIdle(cachedBlob(file, binding, 9), 999_000_000n));
    assert.equal(decodeCheckpoint(cachedBlob(file, binding, 9)).idle, 999_000_000n);

    const restarted = new SolanaSpoke(rpc(history), manifest);
    await restarted.sync(new TransferIndex());
    assert.equal(restarted.checkpoints.length, 10, 'the discarded tail is re-fetched, not dropped');
    assert.equal(restarted.checkpoints[9].idle, 1_000_009n, 'chain amount wins over the cached one');
    // what NAV would have priced from the tampered cache
    const positions = await restarted.positionsAt(restarted.checkpoints[9].slot);
    assert.equal(positions[0].valueBid, 1_000_009n);
    assert.equal(positions[0].valueOffer, 1_000_009n);
    // the bad row is gone from the file too, so a later restart cannot re-trust it
    assert.equal(decodeCheckpoint(cachedBlob(file, binding, 9)).idle, 1_000_009n);
  });
});

test('re-verification covers the newest checkpoints only, and that boundary is explicit', async () => {
  await withCache(async (file) => {
    const first = new SolanaSpoke(rpc(history), manifest);
    await first.sync(new TransferIndex());
    const binding = first.binding;
    // one row inside the re-verified tail, one ten sequences behind it
    tamper(file, binding, 9, withIdle(cachedBlob(file, binding, 9), 999_000_000n));
    tamper(file, binding, 0, withIdle(cachedBlob(file, binding, 0), 111_000_000n));

    const restarted = new SolanaSpoke(rpc(history), manifest);
    await restarted.sync(new TransferIndex());
    assert.equal(restarted.checkpoints[9].idle, 1_000_009n);
    // Residual risk, stated on purpose: rows older than the tail are trusted, as
    // they were before, because re-reading the whole history at every restart is
    // exactly what the cache exists to avoid. Owner-only permissions are what
    // keeps another local user from editing those rows.
    assert.equal(restarted.checkpoints[0].idle, 111_000_000n);
  });
});

test('cached history still has to decode, bind to the agent and stay monotonic', async () => {
  await withCache(async (file) => {
    const first = new SolanaSpoke(rpc(history), manifest);
    await first.sync(new TransferIndex());
    const binding = first.binding,
      stale = Buffer.from(cachedBlob(file, binding, 5));
    stale.writeBigUInt64LE(10n, SLOT_OFFSET); // below the slot of sequence 4
    tamper(file, binding, 5, stale);
    const restarted = new SolanaSpoke(rpc(history), manifest);
    await assert.rejects(() => restarted.sync(new TransferIndex()), /monotonic/);

    // a cache written by another program/agent is not read at all
    const other = new DatabaseSync(file);
    other.exec('PRAGMA busy_timeout=5000');
    other.prepare('DELETE FROM native_checkpoints WHERE binding=?').run(binding);
    other
      .prepare('INSERT INTO native_checkpoints(binding,sequence,data) VALUES(?,?,?)')
      .run('solana:0x8000000000000005:other:other:solana:other', 0, history[0]);
    other.close();
    const fresh = new SolanaSpoke(rpc(history), manifest);
    await fresh.sync(new TransferIndex());
    assert.equal(fresh.checkpoints.length, 10, 'a foreign binding is ignored and history is rebuilt from chain');
    assert.equal(fresh.checkpoints[0].idle, 1_000_000n);
  });
});

test('a cache ahead of finalized chain state is rejected', async () => {
  await withCache(async (file) => {
    const first = new SolanaSpoke(rpc(history), manifest);
    await first.sync(new TransferIndex());
    // the agent now reports fewer checkpoints than the file holds
    const behind = rpc(history.slice(0, 4));
    const restarted = new SolanaSpoke(behind, manifest);
    await assert.rejects(() => restarted.sync(new TransferIndex()), /ahead of finalized chain state/);
  });
});
