import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { PublicKey, Connection, Keypair, TransactionMessage, VersionedTransaction } from '@solana/web3.js';
import { Reserve } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/Reserve';
import { LendingMarket } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/LendingMarket';
import {
  depositReserveLiquidity,
  DISCRIMINATOR as DEPOSIT,
} from '@kamino-finance/klend-sdk/dist/@codegen/klend/instructions/depositReserveLiquidity';
import {
  redeemReserveCollateral,
  DISCRIMINATOR as REDEEM,
} from '@kamino-finance/klend-sdk/dist/@codegen/klend/instructions/redeemReserveCollateral';
import { address, createNoopSigner } from '@solana/kit';
import BN from 'bn.js';
import { SOLANA, SolanaManifest } from '../../deploy/crosschain/native-registry';
import { NETWORKS } from '../../deploy/crosschain/registry';
import { aliasOf, checkpointPda, decodeCheckpoint, discriminator, NativeStrategy, u64 } from '../src/solana/codec';
import {
  burnAccounts,
  receiveAccounts,
  executeInstruction,
  allocateData,
  initializeInstruction,
  LOADER_PROGRAM,
  programDataAddress,
  retireStrategyInstruction,
} from '../src/solana/instructions';
import {
  collateralForAssets,
  kaminoAdapter,
  KAMINO_PROGRAM,
  reserveMetrics,
  tokenAmount,
  TOKEN_PROGRAM,
  valueFromReserve,
} from '../src/solana/kamino';
import { SolanaSpoke, validateManifest } from '../src/solana/spoke';
import { consistentCut, nativeConsistentCut, sortPositions, totals, TransferIndex, Snapshot } from '../src/snapshot';
import type { NativeSpoke } from '../src/native';
import { sendNative } from '../src/solana/transactions';
import { fetchIris } from '../src/cctp';

const key = (n: number) => new PublicKey(Buffer.alloc(32, n));
const strategy: NativeStrategy = {
  protocol: 1,
  reserve: key(1),
  market: key(2),
  marketAuthority: key(3),
  liquiditySupply: key(4),
  collateralMint: key(5),
  collateral: key(6),
  oracles: [KAMINO_PROGRAM, KAMINO_PROGRAM, KAMINO_PROGRAM, key(7)],
  cap: 10_000_000n,
  retired: false,
};
const program = key(9),
  seed = Buffer.alloc(32, 10),
  agent = PublicKey.findProgramAddressSync([Buffer.from('agent'), seed], program)[0];
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
  strategies: [
    { protocol: 'kamino-lending', reserve: strategy.reserve.toBase58(), market: strategy.market.toBase58() },
  ],
};

function checkpoint(
  sequence: bigint,
  slot: bigint,
  time: bigint,
  idleValue: bigint,
  kind = 0,
  id = Buffer.alloc(32, 0),
  observationFailed = 0,
) {
  return Buffer.concat([
    discriminator('account:Checkpoint'),
    agent.toBuffer(),
    u64(sequence),
    u64(slot),
    u64(time),
    u64(idleValue),
    Buffer.from([1, 0, 0, 0]),
    strategy.reserve.toBuffer(),
    u64(5_000_000n),
    u64(6_000_000n),
    Buffer.from([observationFailed]),
    Buffer.from([kind]),
    id,
    u64(8453n),
    u64(kind ? 2_000_000n : 0n),
    u64(kind ? 1_990_000n : 0n),
  ]);
}

test('Solana configuration is explicit and never enters the EVM registry', () => {
  assert.equal(SOLANA.family, 'solana');
  assert.equal(SOLANA.cctp.domain, 5);
  assert.equal(SOLANA.asset.decimals, 6);
  assert.ok(SOLANA.accountingId > 1n << 63n);
  assert.ok(Object.values(NETWORKS).every((e) => e.family === 'evm' && e.chainId !== SOLANA.accountingId));
  assert.doesNotThrow(() => validateManifest(manifest));
  assert.throws(() => validateManifest({ ...manifest, agent: key(8).toBase58() }), /PDA/);
  assert.throws(() => validateManifest({ ...manifest, family: 'evm' as any }), /family/);
  assert.throws(() => validateManifest({ ...manifest, maxCheckpointAgeSeconds: 0 }), /age/);
});
test('native alias uses the Solidity namespace and retains full key significance', () => {
  assert.equal(aliasOf(key(0x61)), '0x3bd1541680c1f5b8be5323ae338bc5ba3f3fa133');
  const a = Buffer.alloc(32, 7),
    b = Buffer.from(a);
  b[0] = 8;
  assert.notEqual(aliasOf(new PublicKey(a)), aliasOf(new PublicKey(b)));
  assert.notEqual(aliasOf(new PublicKey(a)), `0x${a.subarray(12).toString('hex')}`);
});
test('native checkpoint decoder rejects wrong/truncated/malformed history', () => {
  const cp = decodeCheckpoint(checkpoint(2n, 100n, 1_800_000_000n, 1_000_000n));
  assert.equal(cp.sequence, 2n);
  assert.equal(cp.positions[0].value, 6_000_000n);
  assert.equal(cp.positions[0].observationFailed, false);
  assert.equal(
    decodeCheckpoint(checkpoint(2n, 100n, 1_800_000_000n, 1_000_000n, 0, Buffer.alloc(32, 0), 1)).positions[0]
      .observationFailed,
    true,
    'an unreadable reserve is decoded as unknown, never as a zero price',
  );
  assert.equal(checkpoint(0n, 1n, 1n, 0n).length, 133 + 49, 'canonical checkpoint serialization');
  assert.throws(() => decodeCheckpoint(Buffer.alloc(8)), /discriminator/);
  assert.throws(() => decodeCheckpoint(checkpoint(0n, 1n, 1n, 0n).subarray(0, 55)), /truncated/);
  assert.throws(() => decodeCheckpoint(checkpoint(0n, 1n, 1n, 0n, 9)), /movement/);
});
test('initialize binds the agent PDA to the recorded program upgrade authority', () => {
  const governance = Keypair.generate(),
    upgradeAuthority = Keypair.generate(),
    programData = programDataAddress(program);
  assert.equal(
    programData.toBase58(),
    PublicKey.findProgramAddressSync([program.toBuffer()], LOADER_PROGRAM)[0].toBase58(),
  );
  assert.notEqual(programData.toBase58(), program.toBase58());
  const route = Buffer.concat([
    u64(8453n),
    Buffer.from([6, 0, 0, 0]),
    Buffer.alloc(32, 1),
    Buffer.alloc(32, 2),
    Buffer.alloc(32, 3),
    Buffer.alloc(32, 4),
    u64(100_000_000n),
    u64(200_000_000n),
    u64(0n),
    Buffer.from([10, 0]),
  ]);
  assert.equal(route.length, 166);
  const ix = initializeInstruction(
    program,
    agent,
    idle,
    programData,
    upgradeAuthority.publicKey,
    governance.publicKey,
    `0x${seed.toString('hex')}`,
    key(60),
    key(61),
    route,
  );
  assert.equal(ix.keys.length, 8);
  assert.ok(ix.keys[0].pubkey.equals(agent) && ix.keys[0].isWritable && !ix.keys[0].isSigner);
  // ProgramData is read to authenticate the deployer; it is never written.
  assert.ok(ix.keys[1].pubkey.equals(programData) && !ix.keys[1].isWritable && !ix.keys[1].isSigner);
  assert.ok(ix.keys[2].pubkey.equals(upgradeAuthority.publicKey) && ix.keys[2].isSigner);
  assert.ok(ix.keys[3].pubkey.equals(governance.publicKey) && ix.keys[3].isSigner && ix.keys[3].isWritable);
  assert.ok(ix.keys[4].pubkey.equals(idle) && ix.keys[4].isWritable);
  assert.deepEqual(ix.data.subarray(0, 8), discriminator('global:initialize'));
  assert.deepEqual(ix.data.subarray(8, 40), seed);
  // Both signatures and the eight-account message fit one packet: initialize
  // needs no lookup table, so adding the loader accounts cannot push the
  // receive path over the budget that transactions.ts already guards.
  const tx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: governance.publicKey,
      recentBlockhash: key(1).toBase58(),
      instructions: [ix],
    }).compileToV0Message([]),
  );
  tx.sign([governance, upgradeAuthority]);
  assert.ok(tx.serialize().length <= 1232, `initialize packet is ${tx.serialize().length} bytes`);
});
test('a retired strategy carries no observation accounts and retirement is governance-signed', () => {
  const retired = { ...strategy, reserve: key(21), retired: true },
    live = { ...strategy, reserve: key(22) };
  const keys = executeInstruction(program, agent, idle, key(44), 0n, [live, retired], Buffer.from([0])).keys;
  assert.equal(keys.length, 13, 'five fixed accounts, seven per live strategy, plus Kamino');
  assert.ok(keys.at(-1)!.pubkey.equals(KAMINO_PROGRAM));
  assert.ok(keys.some((k) => k.pubkey.equals(live.reserve)));
  assert.ok(
    !keys.some((k) => k.pubkey.equals(retired.reserve)),
    'the program skips a retired reserve, so no accounts may be sent for it',
  );
  const ix = retireStrategyInstruction(program, agent, strategy.collateral, key(50), 3);
  assert.equal(ix.keys.length, 3);
  assert.ok(ix.keys[1].pubkey.equals(strategy.collateral) && !ix.keys[1].isSigner);
  assert.ok(ix.keys[2].pubkey.equals(key(50)) && ix.keys[2].isSigner);
  assert.deepEqual(ix.data, Buffer.concat([discriminator('global:retire_strategy'), Buffer.from([3])]));
  assert.throws(() => retireStrategyInstruction(program, agent, strategy.collateral, key(50), 8), /strategy index/);
});
test('Kamino instruction account order agrees with the official SDK for deposit and redeem', () => {
  const a = address(agent.toBase58()),
    s = strategy,
    owner = createNoopSigner(a);
  const common = {
    owner,
    reserve: address(s.reserve.toBase58()),
    lendingMarket: address(s.market.toBase58()),
    lendingMarketAuthority: address(s.marketAuthority.toBase58()),
    reserveLiquidityMint: address(SOLANA.asset.mint),
    reserveLiquiditySupply: address(s.liquiditySupply.toBase58()),
    reserveCollateralMint: address(s.collateralMint.toBase58()),
    collateralTokenProgram: address(TOKEN_PROGRAM.toBase58()),
    liquidityTokenProgram: address(TOKEN_PROGRAM.toBase58()),
    instructionSysvarAccount: address('Sysvar1nstructions1111111111111111111111111'),
  };
  const deposit = depositReserveLiquidity(
    { liquidityAmount: new BN(1_000_000) },
    {
      ...common,
      userSourceLiquidity: address(idle.toBase58()),
      userDestinationCollateral: address(s.collateral.toBase58()),
    },
  );
  const redeem = redeemReserveCollateral(
    { collateralAmount: new BN(1_000_000) },
    {
      ...common,
      userSourceCollateral: address(s.collateral.toBase58()),
      userDestinationLiquidity: address(idle.toBase58()),
    },
  );
  for (const [sdk, dep] of [
    [deposit, true],
    [redeem, false],
  ] as const) {
    const ours = kaminoAdapter.executionAccounts(agent, idle, s, dep).slice(0, 12);
    assert.deepEqual(
      ours.map((k) => k.pubkey.toBase58()),
      sdk.accounts!.map((k) => k.address),
    );
    assert.deepEqual(
      ours.map((k) => k.isWritable),
      sdk.accounts!.map((k) => (k.role & 1) !== 0),
    );
    assert.ok(
      ours.every((k) => !k.isSigner),
      'PDA signing belongs to CPI only',
    );
  }
  assert.deepEqual(Buffer.from(deposit.data!), Buffer.concat([DEPOSIT, u64(1_000_000n)]));
  assert.deepEqual(Buffer.from(redeem.data!), Buffer.concat([REDEEM, u64(1_000_000n)]));
});
function reserveBytes(available = 100_000_000n, borrowed = 20_000_000n, fees = 1_000_000n) {
  const data = Buffer.alloc(Reserve.layout.span + 8);
  Reserve.discriminator.copy(data);
  data.writeBigUInt64LE(1n, 8);
  data.writeBigUInt64LE(123n, 16);
  strategy.market.toBuffer().copy(data, 32);
  new PublicKey(SOLANA.asset.mint).toBuffer().copy(data, 128);
  strategy.liquiditySupply.toBuffer().copy(data, 160);
  data.writeBigUInt64LE(available, 224);
  function sf(n: bigint, offset: number) {
    const v = n << 60n;
    data.writeBigUInt64LE(v & 0xffffffffffffffffn, offset);
    data.writeBigUInt64LE(v >> 64n, offset + 8);
  }
  sf(borrowed, 232);
  sf(fees, 344);
  data.writeBigUInt64LE(6n, 272);
  strategy.collateralMint.toBuffer().copy(data, 2560);
  data.writeBigUInt64LE(100_000_000n, 2592);
  return data;
}
test('Kamino positions use actual reserve exchange rate, accrue yield and round withdrawals up', () => {
  const state = Reserve.decode(reserveBytes());
  assert.equal(state.liquidity.mintDecimals.toString(), '6');
  assert.equal(state.liquidity.accumulatedProtocolFeesSf.toString(), (1_000_000n << 60n).toString());
  assert.equal(state.collateral.mintTotalSupply.toString(), '100000000');
  assert.equal(valueFromReserve(state, 10_000_000n), 11_900_000n);
  assert.equal(valueFromReserve(Reserve.decode(reserveBytes(110_000_000n)), 10_000_000n), 12_900_000n);
  const units = collateralForAssets(state, 1_000_001n);
  assert.ok(valueFromReserve(state, units) >= 1_000_001n);
  assert.ok(valueFromReserve(state, units - 1n) < 1_000_001n);
});
test('strategy custody rejects wrong mint/authority, frozen tokens and delegates', () => {
  const b = Buffer.alloc(165);
  strategy.collateralMint.toBuffer().copy(b);
  agent.toBuffer().copy(b, 32);
  b.writeBigUInt64LE(44n, 64);
  b[108] = 1;
  assert.equal(tokenAmount(b, strategy.collateralMint, agent), 44n);
  assert.throws(() => tokenAmount(b, key(99), agent), /custody/);
  b.writeUInt32LE(1, 72);
  assert.throws(() => tokenAmount(b, strategy.collateralMint, agent), /custody/);
});
test('supply APR/APY change with reserve utilization through the actual SDK math', async () => {
  const marketBytes = Buffer.alloc(LendingMarket.layout.span + 8);
  LendingMarket.discriminator.copy(marketBytes);
  const market = LendingMarket.decode(marketBytes);
  const connection = {
    rpcEndpoint: 'http://127.0.0.1:8899',
    getBlockTime: async () => 1000,
    getRecentPerformanceSamples: async () => [{ numSlots: 200, samplePeriodSecs: 60 }],
  } as unknown as Connection;
  const rateReserve = (borrowed: bigint) => {
    const json = Reserve.decode(reserveBytes(100_000_000n, borrowed, 0n)).toJSON();
    json.config.protocolTakeRatePct = 10;
    json.config.borrowRateCurve.points = json.config.borrowRateCurve.points.map((_, i) => ({
      utilizationRateBps: i === 0 ? 0 : 10000,
      borrowRateBps: 400,
    }));
    return Reserve.fromJSON(json);
  };
  const low = await reserveMetrics(connection, strategy.reserve, rateReserve(20_000_000n), market, 123, 10_000_000n);
  const high = await reserveMetrics(connection, strategy.reserve, rateReserve(80_000_000n), market, 123, 10_000_000n);
  assert.ok(low.supplyApr > 0 && low.supplyApy > low.supplyApr);
  assert.ok(high.supplyApr > low.supplyApr && high.supplyApy > low.supplyApy);
  assert.equal(low.value, 12_000_000n);
  await assert.rejects(
    () =>
      reserveMetrics(
        { ...connection, getBlockTime: async () => null } as unknown as Connection,
        strategy.reserve,
        rateReserve(1n),
        market,
        123,
        0n,
      ),
    /time unavailable/,
  );
});
test('CCTP prefixes match Circle event-CPI ordering and preserve caller/account keys', () => {
  const payer = key(44),
    event = key(45),
    b = Buffer.alloc(440);
  b.writeUInt32BE(6, 4);
  b.writeUInt32BE(5, 8);
  const burn = burnAccounts(agent, idle, payer, event);
  assert.equal(burn.length, 19);
  assert.ok(burn[11].isSigner);
  assert.ok(!burn[0].isSigner);
  const receive = receiveAccounts(agent, idle, payer, `0x${b.toString('hex')}`, key(46));
  assert.equal(receive.length, 21);
  assert.ok(receive[15].pubkey.equals(idle));
  assert.ok(receive[1].pubkey.equals(agent));
  assert.ok(!receive[1].isSigner);
  const ix = executeInstruction(
    program,
    agent,
    idle,
    payer,
    2n,
    [strategy],
    allocateData(0, 1n, 1n, true),
    kaminoAdapter.executionAccounts(agent, idle, strategy, true),
  );
  assert.ok(ix.keys[3].pubkey.equals(checkpointPda(program, agent, 2n)));
  assert.deepEqual(ix.data.subarray(0, 8), discriminator('global:execute'));
});
test('native finalized historical NAV reads checkpoints rather than current account balances', async () => {
  const spoke = new SolanaSpoke({} as Connection, manifest);
  spoke.checkpoints.push(
    decodeCheckpoint(checkpoint(0n, 100n, 1000n, 1_000_000n)),
    decodeCheckpoint(checkpoint(1n, 200n, 1100n, 3_000_000n)),
  );
  spoke.blockHashes.set(100, `0x${'11'.repeat(32)}`);
  spoke.blockHashes.set(200, `0x${'22'.repeat(32)}`);
  const ref = await spoke.referenceAt(1050);
  assert.equal(ref.blockNumber, 100n);
  assert.equal((await spoke.positionsAt(100))[0].valueBid, 1_000_000n);
  assert.equal((await spoke.positionsAt(200))[0].valueBid, 3_000_000n);
  await assert.rejects(() => spoke.referenceAt(1300), /stale/);
});
test('native NAV fails closed on a position whose observation failed', async () => {
  const spoke = new SolanaSpoke({} as Connection, manifest);
  // The program tolerates a failed reserve observation on Receive and Observe so a dead
  // reserve cannot strand an inbound transfer, and records value 0 with the flag set.
  // Zero here means unknown, so pricing it would under-report NAV; the cut must halt.
  spoke.checkpoints.push(
    decodeCheckpoint(checkpoint(0n, 100n, 1000n, 1_000_000n, 0, Buffer.alloc(32, 0), 1)),
  );
  spoke.blockHashes.set(100, `0x${'11'.repeat(32)}`);
  await assert.rejects(() => spoke.positionsAt(100), /has no observation; NAV cannot be determined/);

  // the identical checkpoint with a successful observation prices normally
  spoke.checkpoints.length = 0;
  spoke.checkpoints.push(decodeCheckpoint(checkpoint(0n, 100n, 1000n, 1_000_000n)));
  const positions = await spoke.positionsAt(100);
  assert.equal(positions[0].valueBid, 1_000_000n);
  assert.equal(positions[1].valueBid, 6_000_000n);
});
test('native write-downs preserve historical cut values and never exceed source principal', async () => {
  const id = Buffer.alloc(32, 55),
    transferId = `0x${id.toString('hex')}`;
  const body = Buffer.concat([
    discriminator('account:Loss'),
    agent.toBuffer(),
    id,
    u64(1_000_000n),
    Buffer.from([2, 0, 0, 0]),
    u64(110n),
    u64(400_000n),
    Buffer.alloc(32, 1),
    u64(130n),
    u64(600_000n),
    Buffer.alloc(32, 2),
  ]);
  const spoke = new SolanaSpoke(
    { getAccountInfo: async () => ({ owner: program, data: body }) } as unknown as Connection,
    manifest,
  );
  spoke.checkpoints.push(decodeCheckpoint(checkpoint(0n, 100n, 1000n, 1_000_000n, 1, id)));
  assert.equal((await spoke.sentAt(transferId, 100)).writtenDown, 0n);
  assert.equal((await spoke.sentAt(transferId, 120)).writtenDown, 400_000n);
  assert.equal((await spoke.sentAt(transferId, 140)).writtenDown, 1_000_000n);
  body.writeBigUInt64LE(9_000_000n, 72);
  await assert.rejects(() => spoke.sentAt(transferId, 140), /exceeds/);
});
test('mixed-family consistent cut removes receipt until both source burn and checkpoint are inside the cut', async () => {
  const index = new TransferIndex(),
    id = `0x${'33'.repeat(32)}`;
  index.sent.set(id, {
    transferId: id,
    chainKey: 'base',
    block: 120,
    txHash: '0x',
    amount: 2_000_000n,
    dstChainId: SOLANA.accountingId,
    minReceive: 1_990_000n,
  });
  index.received.set(id, { transferId: id, chainKey: 'solana', block: 200, txHash: '', amount: 1_990_000n });
  const native = {
    key: 'solana',
    chainId: SOLANA.accountingId,
    referenceAt: async (_t: number, cap: number) => ({
      chainId: SOLANA.accountingId,
      blockNumber: BigInt(cap >= 200 ? 200 : 150),
      blockHash: `0x${'00'.repeat(32)}`,
    }),
  } as NativeSpoke;
  const cut = await nativeConsistentCut(
    new Map([
      ['base', 100],
      ['solana', 200],
    ]),
    index,
    new Map([
      ['base', 100],
      ['solana', 200],
    ]),
    [native],
    2000,
  );
  assert.equal(cut.get('base'), 100);
  assert.equal(cut.get('solana'), 150);
  assert.equal(
    consistentCut(
      new Map([
        ['base', 120],
        ['solana', 200],
      ]),
      index,
    ).get('solana'),
    200,
  );
});
test('native USDC in flight and deposited holdings are counted exactly once', () => {
  const empty: Snapshot = {
    version: 1,
    tickId: 1n,
    referenceTime: 2000n,
    chains: [],
    positions: [],
    inFlight: [],
    hubCash: 0n,
    pendingDeposits: 0n,
    liabilities: 0n,
    totalShares: 10_000_000n,
  };
  const f = {
    transferId: `0x${'33'.repeat(32)}`,
    srcChainId: 8453n,
    dstChainId: SOLANA.accountingId,
    sentAt: 1990n,
    amountSent: 10_000_000n,
    minReceive: 9_990_000n,
    writtenDown: 0n,
  };
  assert.equal(totals({ ...empty, inFlight: [f] }, 100n).navBid, 9_990_000n);
  const positions = sortPositions([
    {
      chainId: SOLANA.accountingId,
      holder: aliasOf(agent),
      strategy: aliasOf(strategy.reserve),
      kind: 1,
      units: 8_000_000n,
      valueBid: 9_990_000n,
      valueOffer: 9_990_000n,
    },
  ]);
  assert.equal(totals({ ...empty, positions }, 100n).navBid, 9_990_000n);
});
test('safe bigint compatibility replacement roundtrips u64/u128 without native bindings', () => {
  const b = require('../vendor/bigint-buffer');
  for (const n of [0n, 1n, 2n ** 64n - 1n, 2n ** 128n - 1n]) {
    assert.equal(b.toBigIntBE(b.toBufferBE(n, 16)), n);
    assert.equal(b.toBigIntLE(b.toBufferLE(n, 16)), n);
  }
  assert.throws(() => b.toBufferLE(256n, 1), /width/);
  assert.throws(() => b.toBufferBE(-1n, 8));
});
test('an ambiguous native broadcast retries identical signed bytes after restart', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'thesauros-native-journal-'));
  const priorDir = process.env.SOLANA_TX_JOURNAL_DIR,
    priorLuts = process.env.SOLANA_LOOKUP_TABLES;
  process.env.SOLANA_TX_JOURNAL_DIR = directory;
  delete process.env.SOLANA_LOOKUP_TABLES;
  const broadcasts: Buffer[] = [];
  let request = 0,
    confirmed = false;
  const connection = {
    getLatestBlockhash: async () => ({ blockhash: key(++request).toBase58(), lastValidBlockHeight: 100 }),
    simulateTransaction: async () => ({ value: { err: null } }),
    getSignatureStatuses: async () => ({ value: [confirmed ? { confirmationStatus: 'finalized', err: null } : null] }),
    getBlockHeight: async () => 1,
    sendRawTransaction: async (bytes: Buffer) => {
      broadcasts.push(Buffer.from(bytes));
      if (broadcasts.length === 1) throw new Error('network lost after accepting signed transaction');
      confirmed = true;
      const record = JSON.parse(fs.readFileSync(path.join(directory, `${agent.toBase58()}-same-intent.json`), 'utf8'));
      return record.signature;
    },
  } as unknown as Connection;
  try {
    const read = {
      ...connection,
      sendRawTransaction: async () => {
        throw new Error('broadcast went to read RPC');
      },
    } as unknown as Connection;
    const signer = Keypair.generate(),
      spoke = new SolanaSpoke(read, manifest, connection);
    await assert.rejects(() => sendNative(spoke, [], signer, [], 'same-intent', true), /network lost/);
    const restarted = new SolanaSpoke(read, manifest, connection);
    const signature = await sendNative(restarted, [], signer, [], 'same-intent', true);
    assert.ok(signature.length > 60);
    assert.equal(broadcasts.length, 2);
    assert.deepEqual(broadcasts[0], broadcasts[1]);
    read.simulateTransaction = async () => {
      throw new Error('changed state must not be re-simulated');
    };
    await sendNative(restarted, [], signer, [], 'same-intent', true);
    assert.equal(broadcasts.length, 2, 'finalized intent is not sent again');
  } finally {
    if (priorDir === undefined) delete process.env.SOLANA_TX_JOURNAL_DIR;
    else process.env.SOLANA_TX_JOURNAL_DIR = priorDir;
    if (priorLuts === undefined) delete process.env.SOLANA_LOOKUP_TABLES;
    else process.env.SOLANA_LOOKUP_TABLES = priorLuts;
  }
});
test('native production runtime checks reviewed ProgramData hash and read/send genesis', async () => {
  const loader = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111'),
    dataKey = key(99);
  const code = Buffer.from('reviewed build'),
    programAccount = Buffer.alloc(36),
    programData = Buffer.alloc(45 + code.length);
  programAccount.writeUInt32LE(2);
  dataKey.toBuffer().copy(programAccount, 4);
  programData.writeUInt32LE(3);
  code.copy(programData, 45);
  const connection = {
    getGenesisHash: async () => SOLANA.genesisHash,
    getAccountInfo: async (p: PublicKey) =>
      p.equals(program)
        ? { executable: true, owner: loader, data: programAccount }
        : p.equals(dataKey)
        ? { executable: false, owner: loader, data: programData }
        : null,
  } as unknown as Connection;
  await assert.rejects(
    () => new SolanaSpoke(connection, { ...manifest, programDataSha256: '0'.repeat(64) }).state(),
    /bytecode differs/,
  );
  const reviewed = new SolanaSpoke(connection, {
    ...manifest,
    programDataSha256: createHash('sha256').update(code).digest('hex'),
  });
  await assert.rejects(() => reviewed.state(), /agent absent/);
  assert.equal(reviewed.upgradeAuthority, undefined);
  programData[12] = 1;
  key(98).toBuffer().copy(programData, 13);
  const upgradeable = new SolanaSpoke(connection, reviewed.manifest);
  await assert.rejects(() => upgradeable.state(), /agent absent/);
  assert.ok(upgradeable.upgradeAuthority?.equals(key(98)));
  const sender = { getGenesisHash: async () => 'wrong genesis' } as unknown as Connection;
  await assert.rejects(() => new SolanaSpoke(connection, manifest, sender).state(), /read\/send RPC genesis mismatch/);
});
test('Iris accepts native signatures and skips unrelated burns without a Thesauros hook', async () => {
  const previous = globalThis.fetch,
    urls: string[] = [];
  const message = Buffer.alloc(440);
  message.fill(71, 376, 408);
  const transferId = `0x${Buffer.alloc(32, 71).toString('hex')}`;
  globalThis.fetch = async (input) => {
    urls.push(String(input));
    return new Response(
      JSON.stringify({
        messages: [
          { status: 'complete', message: `0x${Buffer.alloc(376).toString('hex')}`, attestation: '0x1234' },
          { status: 'complete', message: `0x${message.toString('hex')}`, attestation: '0x5678' },
        ],
      }),
      { status: 200 },
    );
  };
  try {
    const att = await fetchIris(5, 'SolanaBase58Signature', transferId);
    assert.equal(att?.attestation, '0x5678');
    assert.match(urls[0], /\/5\?transactionHash=SolanaBase58Signature$/);
  } finally {
    globalThis.fetch = previous;
  }
});
