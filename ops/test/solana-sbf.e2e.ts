/** Real SBF and SPL-token execution on an isolated local validator.
 * Uses an explicitly named protocol double; makes no mainnet RPC requests. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import {
  AddressLookupTableAccount,
  AddressLookupTableProgram,
  ComputeBudgetProgram,
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  TransactionMessage,
  VersionedTransaction,
  TransactionInstruction,
} from '@solana/web3.js';
import { createTransferInstruction, getAssociatedTokenAddressSync } from '@solana/spl-token';
import { concat, getBytes, hexlify, keccak256, SigningKey, computeAddress, zeroPadValue } from 'ethers';
import { SOLANA } from '../../deploy/crosschain/native-registry';
import { checkpointPda, decodeAgent, decodeCheckpoint, discriminator, NativeStrategy, u64 } from '../src/solana/codec';
import {
  allocateData,
  executeInstruction,
  bridgeData,
  burnAccounts,
  pda,
  receiveAccounts,
  receiveData,
} from '../src/solana/instructions';
import { KAMINO_PROGRAM, kaminoAdapter, meta, TOKEN_PROGRAM } from '../src/solana/kamino';
import { SolanaSpoke } from '../src/solana/spoke';
import { TransferIndex } from '../src/snapshot';

async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'thesauros-solana-sbf-'));
  const program = new PublicKey('Fg6PaFpoGXkYsidMpWxTWqkZ2dKjF6Q6Bf6WZ7H6LJ7');
  const payer = Keypair.generate(),
    attacker = Keypair.generate(),
    seed = Buffer.alloc(32, 12);
  const agent = PublicKey.findProgramAddressSync([Buffer.from('agent'), seed], program)[0];
  const idle = PublicKey.findProgramAddressSync([Buffer.from('idle'), agent.toBuffer()], program)[0];
  const mint = new PublicKey(SOLANA.asset.mint),
    reserve = Keypair.generate().publicKey,
    market = Keypair.generate().publicKey;
  const auth = PublicKey.findProgramAddressSync([Buffer.from('lma'), market.toBuffer()], KAMINO_PROGRAM)[0];
  const supply = Keypair.generate().publicKey,
    cmint = Keypair.generate().publicKey,
    collateral = Keypair.generate().publicKey,
    funds = getAssociatedTokenAddressSync(mint, payer.publicKey);
  const baseWord = (n: number) => Buffer.concat([Buffer.alloc(12), Buffer.alloc(20, n)]);
  const baseAgent = baseWord(1),
    baseAdapter = baseWord(2),
    baseMint = baseWord(3),
    baseMessenger = baseWord(4);
  const realCircle = process.argv.includes('--real-cctp') || process.env.SOLANA_TEST_REAL_CCTP === 'true';
  const tm = new PublicKey(SOLANA.cctp.tokenMessenger),
    mt = new PublicKey(SOLANA.cctp.messageTransmitter);
  const attester = new SigningKey(`0x${'11'.repeat(32)}`); // Local test attester only.
  const fixtures: string[] = [];
  function account(key: PublicKey, owner: PublicKey, data: Buffer, lamports = 100_000_000) {
    const file = path.join(dir, `${key.toBase58()}.json`);
    fs.writeFileSync(
      file,
      JSON.stringify({
        pubkey: key.toBase58(),
        account: {
          lamports,
          data: [data.toString('base64'), 'base64'],
          owner: owner.toBase58(),
          executable: false,
          rentEpoch: 0,
          space: data.length,
        },
      }),
    );
    fixtures.push('--account', key.toBase58(), file);
  }
  function token(key: PublicKey, m: PublicKey, owner: PublicKey, amount: bigint) {
    const b = Buffer.alloc(165);
    m.toBuffer().copy(b);
    owner.toBuffer().copy(b, 32);
    b.writeBigUInt64LE(amount, 64);
    b[108] = 1;
    account(key, TOKEN_PROGRAM, b);
  }
  function mintAccount(key: PublicKey, authority: PublicKey, supply: bigint) {
    const b = Buffer.alloc(82);
    b.writeUInt32LE(1);
    authority.toBuffer().copy(b, 4);
    b.writeBigUInt64LE(supply, 36);
    b[44] = 6;
    b[45] = 1;
    account(key, TOKEN_PROGRAM, b);
  }
  account(payer.publicKey, SystemProgram.programId, Buffer.alloc(0), 100_000_000_000);
  account(attacker.publicKey, SystemProgram.programId, Buffer.alloc(0), 100_000_000_000);
  mintAccount(mint, payer.publicKey, 1_100_000_000n);
  mintAccount(cmint, auth, 100_000_000n);
  token(funds, mint, payer.publicKey, 1_000_000_000n);
  token(supply, mint, auth, 100_000_000n);
  token(collateral, cmint, agent, 0n);
  const circlePrograms: string[] = [];
  if (realCircle) {
    const argument = (flag: string) => {
      const i = process.argv.indexOf(flag);
      return i < 0 ? undefined : process.argv[i + 1];
    };
    const tmBin = argument('--token-messenger') ?? process.env.CCTP_TOKEN_MESSENGER_BINARY,
      mtBin = argument('--message-transmitter') ?? process.env.CCTP_MESSAGE_TRANSMITTER_BINARY;
    if (!tmBin || !mtBin || !fs.existsSync(tmBin) || !fs.existsSync(mtBin))
      throw new Error('set paths to read-only mainnet CCTP program dumps');
    circlePrograms.push(
      '--upgradeable-program',
      tm.toBase58(),
      tmBin,
      'none',
      '--upgradeable-program',
      mt.toBase58(),
      mtBin,
      'none',
    );
    const bump = (program: PublicKey, name: string, ...seeds: Buffer[]) =>
      PublicKey.findProgramAddressSync([Buffer.from(name), ...seeds], program)[1];
    const uint32 = (v: number) => {
      const b = Buffer.alloc(4);
      b.writeUInt32LE(v);
      return b;
    };
    account(
      pda(mt, 'message_transmitter'),
      mt,
      Buffer.concat([
        discriminator('account:MessageTransmitter'),
        payer.publicKey.toBuffer(),
        Buffer.alloc(32),
        payer.publicKey.toBuffer(),
        payer.publicKey.toBuffer(),
        Buffer.from([0]),
        uint32(5),
        uint32(1),
        uint32(1),
        uint32(1),
        Buffer.from(getBytes(zeroPadValue(computeAddress(attester.publicKey), 32))),
        u64(1024n),
      ]),
    );
    account(
      pda(tm, 'token_messenger'),
      tm,
      Buffer.concat([
        discriminator('account:TokenMessenger'),
        payer.publicKey.toBuffer(),
        payer.publicKey.toBuffer(),
        Buffer.alloc(32),
        uint32(1),
        Buffer.from([bump(tm, 'sender_authority')]),
        payer.publicKey.toBuffer(),
        payer.publicKey.toBuffer(),
        uint32(0),
      ]),
    );
    account(
      pda(tm, 'remote_token_messenger', Buffer.from('6')),
      tm,
      Buffer.concat([discriminator('account:RemoteTokenMessenger'), uint32(6), baseMessenger]),
    );
    account(
      pda(tm, 'token_minter'),
      tm,
      Buffer.concat([
        discriminator('account:TokenMinter'),
        payer.publicKey.toBuffer(),
        payer.publicKey.toBuffer(),
        Buffer.from([0, bump(tm, 'token_minter')]),
      ]),
    );
    const local = pda(tm, 'local_token', mint.toBuffer()),
      custody = pda(tm, 'custody', mint.toBuffer());
    account(
      local,
      tm,
      Buffer.concat([
        discriminator('account:LocalToken'),
        custody.toBuffer(),
        mint.toBuffer(),
        u64(100_000_000n),
        u64(0n),
        u64(0n),
        Buffer.alloc(32),
        Buffer.from([bump(tm, 'local_token', mint.toBuffer()), bump(tm, 'custody', mint.toBuffer())]),
      ]),
    );
    account(
      pda(tm, 'token_pair', Buffer.from('6'), baseMint),
      tm,
      Buffer.concat([
        discriminator('account:TokenPair'),
        uint32(6),
        baseMint,
        local.toBuffer(),
        Buffer.from([bump(tm, 'token_pair', Buffer.from('6'), baseMint)]),
      ]),
    );
    token(custody, mint, pda(tm, 'token_minter'), 100_000_000n);
  }
  account(market, KAMINO_PROGRAM, Buffer.alloc(8));
  const r = Buffer.alloc(8624);
  discriminator('account:Reserve').copy(r);
  r.writeBigUInt64LE(1n, 8);
  market.toBuffer().copy(r, 32);
  mint.toBuffer().copy(r, 128);
  supply.toBuffer().copy(r, 160);
  r.writeBigUInt64LE(100_000_000n, 224);
  r.writeBigUInt64LE(6n, 272);
  cmint.toBuffer().copy(r, 2560);
  r.writeBigUInt64LE(100_000_000n, 2592);
  account(reserve, KAMINO_PROGRAM, r);
  const root = path.resolve(__dirname, '../..');
  const agentBinary = path.join(root, 'solana/target/deploy/thesauros_chain_agent.so');
  const mockBinary = path.join(root, 'solana/target/deploy/thesauros_test_kamino.so');
  for (const file of [agentBinary, mockBinary]) if (!fs.existsSync(file)) throw new Error(`build SBF first: ${file}`);
  const rpcPort = Number(process.env.SOLANA_TEST_PORT ?? 18999);
  const log = fs.openSync(path.join(dir, 'validator.log'), 'w');
  const validator = spawn(
    'solana-test-validator',
    [
      '--ledger',
      path.join(dir, 'ledger'),
      '--rpc-port',
      String(rpcPort),
      '--faucet-port',
      String(rpcPort + 2),
      '--gossip-port',
      String(rpcPort + 3),
      '--dynamic-port-range',
      `${rpcPort + 10}-${rpcPort + 50}`,
      '--bind-address',
      '127.0.0.1',
      '--upgradeable-program',
      program.toBase58(),
      agentBinary,
      'none',
      '--upgradeable-program',
      KAMINO_PROGRAM.toBase58(),
      mockBinary,
      'none',
      ...circlePrograms,
      ...fixtures,
      '--quiet',
    ],
    { stdio: ['ignore', log, log] },
  );
  const c = new Connection(`http://127.0.0.1:${rpcPort}`, 'confirmed');
  let lookupTables: AddressLookupTableAccount[] = [];
  const state = async () => decodeAgent((await c.getAccountInfo(agent, 'confirmed'))!.data);
  async function send(ixs: TransactionInstruction[], signer = payer, additional: Keypair[] = []) {
    const latest = await c.getLatestBlockhash('confirmed');
    const tx = new VersionedTransaction(
      new TransactionMessage({
        payerKey: signer.publicKey,
        recentBlockhash: latest.blockhash,
        instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_200_000 }), ...ixs],
      }).compileToV0Message(lookupTables),
    );
    tx.sign([signer, ...additional]);
    const sig = await c.sendRawTransaction(tx.serialize(), { skipPreflight: false });
    for (let i = 0; i < 600; i++) {
      const result = (await c.getSignatureStatuses([sig])).value[0];
      if (result?.err) throw new Error(JSON.stringify(result.err));
      if (result?.confirmationStatus === 'confirmed' || result?.confirmationStatus === 'finalized') return sig;
      if (i > 0 && i % 20 === 0) await c.sendRawTransaction(tx.serialize(), { skipPreflight: true, maxRetries: 0 });
      await delay(50);
    }
    throw new Error(`local transaction did not confirm: ${sig}`);
  }
  const strategy: NativeStrategy = {
    protocol: 1,
    reserve,
    market,
    marketAuthority: auth,
    liquiditySupply: supply,
    collateralMint: cmint,
    collateral,
    oracles: [KAMINO_PROGRAM, KAMINO_PROGRAM, KAMINO_PROGRAM, KAMINO_PROGRAM],
    cap: 100_000_000n,
  };
  try {
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (validator.exitCode !== null)
        throw new Error(`validator exited: ${fs.readFileSync(path.join(dir, 'validator.log'), 'utf8').slice(-4000)}`);
      try {
        await c.getLatestBlockhash();
        ready = true;
        break;
      } catch {
        await delay(200);
      }
    }
    if (!ready) throw new Error('local validator did not start');
    for (let i = 0; i < 50 && (await c.getSlot('confirmed')) < 3; i++) await delay(100);
    const domain = Buffer.alloc(4);
    domain.writeUInt32LE(6);
    const fee = Buffer.alloc(2);
    fee.writeUInt16LE(10);
    const route = Buffer.concat([
      u64(8453n),
      domain,
      baseAgent,
      baseAdapter,
      baseMint,
      baseMessenger,
      u64(100_000_000n),
      u64(200_000_000n),
      u64(0n),
      fee,
    ]);
    await send([
      new TransactionInstruction({
        programId: program,
        keys: [
          meta(agent, true),
          meta(payer.publicKey, true, true),
          meta(idle, true),
          meta(mint),
          meta(TOKEN_PROGRAM),
          meta(SystemProgram.programId),
        ],
        data: Buffer.concat([
          discriminator('global:initialize'),
          seed,
          payer.publicKey.toBuffer(),
          payer.publicKey.toBuffer(),
          route,
        ]),
      }),
    ]);
    const strategyData = Buffer.concat([
      Buffer.from([1]),
      reserve.toBuffer(),
      market.toBuffer(),
      auth.toBuffer(),
      supply.toBuffer(),
      cmint.toBuffer(),
      collateral.toBuffer(),
      ...strategy.oracles.map((o) => o.toBuffer()),
      u64(strategy.cap),
    ]);
    await send([
      new TransactionInstruction({
        programId: program,
        keys: [meta(agent, true), meta(payer.publicKey, false, true)],
        data: Buffer.concat([discriminator('global:add_strategy'), strategyData]),
      }),
    ]);
    assert.equal((await state()).paused, true);
    await send([
      new TransactionInstruction({
        programId: program,
        keys: [meta(agent, true), meta(payer.publicKey, false, true)],
        data: Buffer.concat([discriminator('global:pause'), Buffer.from([0])]),
      }),
    ]);
    await send([createTransferInstruction(funds, idle, payer.publicKey, 20_000_000n)]);
    const execute = async (
      data: Buffer,
      prefix: ReturnType<typeof kaminoAdapter.executionAccounts> = [],
      signer = payer,
    ) => {
      const s = await state();
      return send(
        [executeInstruction(program, agent, idle, signer.publicKey, s.sequence, s.strategies, data, prefix)],
        signer,
      );
    };
    await execute(Buffer.from([0]));
    let cp = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 0n), 'confirmed'))!.data);
    assert.equal(cp.idle, 20_000_000n);
    assert.equal(cp.positions[0].units, 0n);
    await assert.rejects(
      () =>
        execute(
          allocateData(0, 10_000_000n, 9_990_000n, true),
          kaminoAdapter.executionAccounts(agent, idle, strategy, true),
          attacker,
        ),
      /Unauthorized|0x1770/,
    );
    assert.equal((await state()).sequence, 1n);
    await execute(
      allocateData(0, 10_000_000n, 9_990_000n, true),
      kaminoAdapter.executionAccounts(agent, idle, strategy, true),
    );
    cp = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 1n), 'confirmed'))!.data);
    assert.equal(cp.idle, 10_000_000n);
    assert.equal(cp.positions[0].units, 10_000_000n);
    assert.equal(cp.positions[0].value, 10_000_000n);
    // A failed minimum rolls back SPL transfers AND checkpoint creation.
    await assert.rejects(
      () =>
        execute(
          allocateData(0, 1_000_000n, 2_000_000n, true),
          kaminoAdapter.executionAccounts(agent, idle, strategy, true),
        ),
      /minimum|0x1777|Slippage/,
    );
    assert.equal((await state()).sequence, 2n);
    await send([
      new TransactionInstruction({
        programId: program,
        keys: [meta(agent, true), meta(payer.publicKey, false, true)],
        data: Buffer.concat([discriminator('global:pause'), Buffer.from([1])]),
      }),
    ]);
    await assert.rejects(
      () =>
        execute(
          allocateData(0, 1_000_000n, 999_000n, true),
          kaminoAdapter.executionAccounts(agent, idle, strategy, true),
        ),
      /paused|0x1771/,
    );
    await execute(
      allocateData(0, 10_000_000n, 9_990_000n, false),
      kaminoAdapter.executionAccounts(agent, idle, strategy, false),
    );
    cp = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 2n), 'confirmed'))!.data);
    assert.equal(cp.idle, 20_000_000n);
    assert.equal(cp.positions[0].units, 0n);
    assert.equal(cp.idle + cp.positions[0].value, 20_000_000n);
    const wrong = kaminoAdapter.executionAccounts(agent, idle, strategy, false);
    wrong[8] = meta(funds, true);
    await assert.rejects(() => execute(allocateData(0, 1n, 1n, false), wrong), /account|0x1773/);
    if (realCircle) {
      await send([
        new TransactionInstruction({
          programId: program,
          keys: [meta(agent, true), meta(payer.publicKey, false, true)],
          data: Buffer.concat([discriminator('global:pause'), Buffer.from([0])]),
        }),
      ]);
      const event = Keypair.generate(),
        s = await state();
      await send(
        [
          executeInstruction(
            program,
            agent,
            idle,
            payer.publicKey,
            s.sequence,
            s.strategies,
            bridgeData(4_000_000n, 4_000_000n),
            burnAccounts(agent, idle, payer.publicKey, event.publicKey),
          ),
        ],
        payer,
        [event],
      );
      cp = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 3n), 'confirmed'))!.data);
      assert.equal(cp.idle, 16_000_000n);
      assert.equal(cp.movement.kind, 1);
      assert.equal(cp.movement.amount, 4_000_000n);
      const sent = (await c.getAccountInfo(event.publicKey, 'confirmed'))!.data;
      const wire = sent.subarray(52, 52 + sent.readUInt32LE(48));
      assert.equal(wire.length, 440);
      assert.ok(wire.subarray(248, 280).equals(agent.toBuffer()));
      assert.equal(hexlify(wire.subarray(376, 408)), cp.movement.transferId);
      const inbound = Buffer.alloc(440);
      inbound.writeUInt32BE(1, 0);
      inbound.writeUInt32BE(6, 4);
      inbound.writeUInt32BE(5, 8);
      Buffer.from(getBytes(keccak256(Buffer.from('local Circle nonce')))).copy(inbound, 12);
      baseMessenger.copy(inbound, 44);
      tm.toBuffer().copy(inbound, 76);
      agent.toBuffer().copy(inbound, 108);
      inbound.writeUInt32BE(2000, 140);
      inbound.writeUInt32BE(2000, 144);
      inbound.writeUInt32BE(1, 148);
      baseMint.copy(inbound, 152);
      idle.toBuffer().copy(inbound, 184);
      inbound.writeBigUInt64BE(4_000_000n, 240);
      baseAdapter.copy(inbound, 248);
      Buffer.from(getBytes(keccak256(Buffer.from('base-to-solana transfer')))).copy(inbound, 376);
      baseAgent.copy(inbound, 408);
      const signature = attester.sign(keccak256(inbound)).serialized;
      // CCTP's message + attestation and native checkpoint exceed the legacy
      // packet limit. Exercise the same v0/lookup-table path as production.
      const receiveKeys = executeInstruction(
        program,
        agent,
        idle,
        payer.publicKey,
        4n,
        [strategy],
        receiveData(hexlify(inbound), signature),
        receiveAccounts(agent, idle, payer.publicKey, hexlify(inbound), funds),
      ).keys;
      const addresses = [
        ...new Map(receiveKeys.filter((k) => !k.isSigner).map((k) => [k.pubkey.toBase58(), k.pubkey])).values(),
      ];
      const [create, tableKey] = AddressLookupTableProgram.createLookupTable({
        authority: payer.publicKey,
        payer: payer.publicKey,
        recentSlot: (await c.getSlot('confirmed')) - 1,
      });
      await send([create]);
      for (let at = 0; at < addresses.length; at += 20)
        await send([
          AddressLookupTableProgram.extendLookupTable({
            lookupTable: tableKey,
            authority: payer.publicKey,
            payer: payer.publicKey,
            addresses: addresses.slice(at, at + 20),
          }),
        ]);
      const table = (await c.getAddressLookupTable(tableKey)).value!;
      for (let i = 0; i < 50 && (await c.getSlot('confirmed')) <= table.state.lastExtendedSlot; i++) await delay(100);
      lookupTables = [table];
      const receive = async (message: Buffer, attestation: string) => {
        const st = await state();
        return send([
          executeInstruction(
            program,
            agent,
            idle,
            payer.publicKey,
            st.sequence,
            st.strategies,
            receiveData(hexlify(message), attestation),
            receiveAccounts(agent, idle, payer.publicKey, hexlify(message), funds),
          ),
        ]);
      };
      await assert.rejects(() => receive(inbound, `0x${'00'.repeat(65)}`), /attest|signature|recover|0x/);
      const forged = Buffer.from(inbound);
      forged[248] ^= 1;
      await assert.rejects(() => receive(forged, signature), /message|0x/);
      await send([
        new TransactionInstruction({
          programId: program,
          keys: [meta(agent, true), meta(payer.publicKey, false, true)],
          data: Buffer.concat([discriminator('global:pause'), Buffer.from([1])]),
        }),
      ]);
      await receive(inbound, signature);
      cp = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 4n), 'confirmed'))!.data);
      assert.equal(cp.idle, 20_000_000n);
      assert.equal(cp.movement.kind, 2);
      await assert.rejects(() => receive(inbound, signature), /already|in use|0x/);
      const out = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 3n), 'confirmed'))!.data);
      const loss = pda(program, 'loss', agent.toBuffer(), Buffer.from(getBytes(out.movement.transferId)));
      await send([
        new TransactionInstruction({
          programId: program,
          keys: [
            meta(agent),
            meta(checkpointPda(program, agent, 3n)),
            meta(loss, true),
            meta(payer.publicKey, true, true),
            meta(SystemProgram.programId),
          ],
          data: Buffer.concat([
            discriminator('global:write_down'),
            Buffer.from(getBytes(out.movement.transferId)),
            u64(1_000_000n),
            Buffer.alloc(32, 1),
          ]),
        }),
      ]);
      assert.ok(await c.getAccountInfo(loss, 'confirmed'));
      await assert.rejects(
        () =>
          send([
            new TransactionInstruction({
              programId: program,
              keys: [
                meta(agent),
                meta(checkpointPda(program, agent, 3n)),
                meta(loss, true),
                meta(payer.publicKey, true, true),
                meta(SystemProgram.programId),
              ],
              data: Buffer.concat([
                discriminator('global:write_down'),
                Buffer.from(getBytes(out.movement.transferId)),
                u64(4_000_000n),
                Buffer.alloc(32, 1),
              ]),
            }),
          ]),
        /limit|0x/,
      );
      await execute(Buffer.from([0]));
      const last = decodeCheckpoint((await c.getAccountInfo(checkpointPda(program, agent, 5n), 'confirmed'))!.data);
      for (let i = 0; i < 400 && (await c.getSlot('finalized')) < last.slot; i++) await delay(100);
      assert.ok((await c.getSlot('finalized')) >= last.slot, 'native runtime reads finalized checkpoints only');
      const localManifest = {
        family: 'solana' as const,
        network: SOLANA.network,
        program: program.toBase58(),
        seed: hexlify(seed),
        agent: agent.toBase58(),
        idle: idle.toBase58(),
        hubAgent: hexlify(baseAgent.subarray(12)),
        hubAdapter: hexlify(baseAdapter.subarray(12)),
        maxCheckpointAgeSeconds: 480,
        localValidator: true,
        genesisHash: await c.getGenesisHash(),
        strategies: [{ protocol: 'kamino-lending' as const, reserve: reserve.toBase58(), market: market.toBase58() }],
      };
      const saved = process.env.SOLANA_CHECKPOINT_DB;
      process.env.SOLANA_CHECKPOINT_DB = path.join(dir, 'checkpoints.sqlite');
      try {
        const native = new SolanaSpoke(c, localManifest),
          index = new TransferIndex();
        await native.sync(index);
        assert.equal(index.sent.size, 1);
        assert.equal(index.received.size, 1);
        assert.ok(index.sent.get(out.movement.transferId)!.txHash.length > 60);
        assert.equal((await native.positionsAt(last.slot))[0].valueBid, 20_000_000n);
        assert.equal((await native.sentAt(out.movement.transferId, last.slot)).writtenDown, 1_000_000n);
        const ref = await native.referenceAt(last.timestamp);
        assert.equal(ref.blockNumber, BigInt(last.slot));
        const restarted = new SolanaSpoke(c, localManifest);
        await restarted.sync(new TransferIndex());
        assert.equal(restarted.checkpoints.length, 6, 'durable cache restores history after a restart');
      } finally {
        if (saved === undefined) delete process.env.SOLANA_CHECKPOINT_DB;
        else process.env.SOLANA_CHECKPOINT_DB = saved;
      }
      console.log(
        'PASS native accounting runtime: finalized PDA reads, authenticated transfer indexing, historical balances, write-down cut, block hash and SQLite restart recovery',
      );
      console.log(
        'PASS deployed Circle CCTP V2 bytecode in local VM: native PDA burn, real secp256k1 attestation, authenticated receive during pause, replay/forgery rejection, balance conservation and governance write-down',
      );
    }
    console.log(
      'PASS real SBF/SPL CPI: initialize, observe, deposit, full redeem, principal conservation, executor authorization, minimum-output rollback, pause and unwind, recipient pinning',
    );
  } finally {
    validator.kill('SIGTERM');
    await Promise.race([new Promise<void>((resolve) => validator.once('exit', () => resolve())), delay(5000)]);
    if (validator.exitCode === null) validator.kill('SIGKILL');
    fs.closeSync(log);
    console.log(`Local-validator evidence: ${dir}`);
  }
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
