import { createHash } from 'node:crypto';
import { PublicKey } from '@solana/web3.js';
import { concat, getBytes, hexlify, keccak256, toUtf8Bytes } from 'ethers';

export const discriminator = (name: string): Buffer => createHash('sha256').update(name).digest().subarray(0, 8);
export const aliasOf = (key: PublicKey): string =>
  `0x${keccak256(concat([toUtf8Bytes('thesauros.solana.identity.v1:'), key.toBytes()])).slice(-40)}`;
export const u64 = (n: bigint): Buffer => {
  if (n < 0n || n > 0xffffffffffffffffn) throw new Error('u64 out of range');
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(n);
  return b;
};
export const vector = (data: Uint8Array): Buffer => {
  const n = Buffer.alloc(4);
  n.writeUInt32LE(data.length);
  return Buffer.concat([n, data]);
};

export class Reader {
  offset = 0;
  constructor(readonly bytes: Buffer) {}
  take(n: number): Buffer {
    if (!Number.isSafeInteger(n) || n < 0 || this.offset + n > this.bytes.length)
      throw new Error('truncated native account');
    const b = this.bytes.subarray(this.offset, this.offset + n);
    this.offset += n;
    return b;
  }
  u8(): number {
    return this.take(1)[0];
  }
  u32(): number {
    return this.take(4).readUInt32LE();
  }
  u64(): bigint {
    return this.take(8).readBigUInt64LE();
  }
  i64(): bigint {
    return this.take(8).readBigInt64LE();
  }
  key(): PublicKey {
    return new PublicKey(this.take(32));
  }
}
export interface NativeCheckpoint {
  agent: PublicKey;
  sequence: bigint;
  slot: number;
  timestamp: number;
  idle: bigint;
  positions: { reserve: PublicKey; units: bigint; value: bigint }[];
  movement: { kind: number; transferId: string; peerChain: bigint; amount: bigint; minimum: bigint };
}
export function safeNumber(n: bigint): number {
  const v = Number(n);
  if (!Number.isSafeInteger(v) || v < 0) throw new Error('unsafe integer in native account');
  return v;
}
export function decodeCheckpoint(data: Buffer): NativeCheckpoint {
  const r = new Reader(data);
  if (!r.take(8).equals(discriminator('account:Checkpoint'))) throw new Error('wrong checkpoint discriminator');
  const agent = r.key(),
    sequence = r.u64(),
    slot = safeNumber(r.u64()),
    timestamp = safeNumber(r.i64()),
    idle = r.u64();
  const count = r.u32();
  if (count > 8) throw new Error('too many native positions');
  const positions = Array.from({ length: count }, () => ({ reserve: r.key(), units: r.u64(), value: r.u64() }));
  const movement = {
    kind: r.u8(),
    transferId: hexlify(r.take(32)),
    peerChain: r.u64(),
    amount: r.u64(),
    minimum: r.u64(),
  };
  if (movement.kind > 2 || movement.minimum > movement.amount) throw new Error('invalid native movement');
  return { agent, sequence, slot, timestamp, idle, positions, movement };
}
export const checkpointPda = (program: PublicKey, agent: PublicKey, sequence: bigint): PublicKey =>
  PublicKey.findProgramAddressSync([Buffer.from('checkpoint'), agent.toBuffer(), u64(sequence)], program)[0];

export interface NativeStrategy {
  protocol: number;
  reserve: PublicKey;
  market: PublicKey;
  marketAuthority: PublicKey;
  liquiditySupply: PublicKey;
  collateralMint: PublicKey;
  collateral: PublicKey;
  oracles: PublicKey[];
  cap: bigint;
}
export function decodeAgent(data: Buffer) {
  const r = new Reader(data);
  if (!r.take(8).equals(discriminator('account:Agent'))) throw new Error('wrong agent discriminator');
  const seed = r.take(32),
    bump = r.u8(),
    governance = r.key(),
    executor = r.key(),
    guardian = r.key(),
    idle = r.key();
  const paused = r.u8() !== 0,
    sequence = r.u64();
  const route = {
    chainId: r.u64(),
    domain: r.u32(),
    agent: hexlify(r.take(32)),
    adapter: hexlify(r.take(32)),
    mint: hexlify(r.take(32)),
    tokenMessenger: hexlify(r.take(32)),
    maxPerTransfer: r.u64(),
    capacity: r.u64(),
    refillPerSecond: r.u64(),
    maxFeeBps: r.take(2).readUInt16LE(),
  };
  const level = r.u64(),
    updatedAt = r.i64(),
    count = r.u32();
  if (count > 8) throw new Error('too many strategies');
  const strategies: NativeStrategy[] = Array.from({ length: count }, () => ({
    protocol: r.u8(),
    reserve: r.key(),
    market: r.key(),
    marketAuthority: r.key(),
    liquiditySupply: r.key(),
    collateralMint: r.key(),
    collateral: r.key(),
    oracles: Array.from({ length: 4 }, () => r.key()),
    cap: r.u64(),
  }));
  return { seed, bump, governance, executor, guardian, idle, paused, sequence, route, level, updatedAt, strategies };
}
export function seedBytes(seed: string): Buffer {
  const b = Buffer.from(getBytes(seed));
  if (b.length !== 32) throw new Error('agent seed must be bytes32');
  return b;
}
