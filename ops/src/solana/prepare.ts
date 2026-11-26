/** Build reviewable unsigned native initialization/configuration instructions. */
import { AddressLookupTableProgram, PublicKey, TransactionInstruction } from '@solana/web3.js';
import { createAssociatedTokenAccountIdempotentInstruction, getAssociatedTokenAddressSync } from '@solana/spl-token';
import { zeroPadValue, getBytes } from 'ethers';
import { Reserve } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/Reserve';
import { NETWORKS } from '../../../deploy/crosschain/registry';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { discriminator, NativeStrategy, Reader, u64 } from './codec';
import { KAMINO_PROGRAM, meta } from './kamino';
import { SolanaSpoke } from './spoke';
import {
  burnAccounts,
  executeInstruction,
  initializeInstruction,
  LOADER_PROGRAM,
  pda,
  programDataAddress,
  receiveAccounts,
} from './instructions';

export interface NativePreparation {
  governance: string;
  executor: string;
  guardian: string;
  maxPerTransfer: string;
  capacity: string;
  refillPerSecond: string;
  maxFeeBps: number;
  strategyCaps: Record<string, string>;
}
export async function prepareNative(spoke: SolanaSpoke, config: NativePreparation) {
  const governance = new PublicKey(config.governance),
    executor = new PublicKey(config.executor),
    guardian = new PublicKey(config.guardian);
  const max = BigInt(config.maxPerTransfer),
    cap = BigInt(config.capacity),
    refill = BigInt(config.refillPerSecond);
  if (
    max <= 0n ||
    cap < max ||
    refill < 0n ||
    !Number.isInteger(config.maxFeeBps) ||
    config.maxFeeBps < 0 ||
    config.maxFeeBps >= 10000
  )
    throw new Error('invalid reviewed native route limits');
  const domain = Buffer.alloc(4);
  domain.writeUInt32LE(NETWORKS.base.cctp.domain);
  const fee = Buffer.alloc(2);
  fee.writeUInt16LE(config.maxFeeBps);
  const route = Buffer.concat([
    u64(NETWORKS.base.chainId),
    domain,
    Buffer.from(getBytes(zeroPadValue(spoke.manifest.hubAgent, 32))),
    Buffer.from(getBytes(zeroPadValue(spoke.manifest.hubAdapter, 32))),
    Buffer.from(getBytes(zeroPadValue(NETWORKS.base.usdc, 32))),
    Buffer.from(getBytes(zeroPadValue(NETWORKS.base.cctp.tokenMessenger, 32))),
    u64(max),
    u64(cap),
    u64(refill),
    fee,
  ]);
  if (!spoke.manifest.localValidator && (await spoke.connection.getGenesisHash()) !== SOLANA.genesisHash)
    throw new Error('preparation RPC is not Solana mainnet');
  // `initialize` authenticates the caller against the loader's ProgramData, so
  // the seed being public in this plan no longer lets anyone claim the PDA.
  const programData = programDataAddress(spoke.program);
  const loaderInfo = await spoke.connection.getAccountInfo(programData, 'finalized');
  if (
    !loaderInfo ||
    !loaderInfo.owner.equals(LOADER_PROGRAM) ||
    loaderInfo.data.length < 45 ||
    loaderInfo.data.readUInt32LE() !== 3
  )
    throw new Error('native ProgramData unavailable/wrong owner');
  // 45-byte loader header: state tag(4), slot(8), option(1), authority(32).
  if (loaderInfo.data[12] !== 1)
    throw new Error(
      'the deployed program records no upgrade authority, so initialize can never be authorized; redeploy under the reviewed authority',
    );
  const upgradeAuthority = new PublicKey(loaderInfo.data.subarray(13, 45));
  const instructions = [
    initializeInstruction(
      spoke.program,
      spoke.agent,
      spoke.idle,
      programData,
      upgradeAuthority,
      governance,
      spoke.manifest.seed,
      executor,
      guardian,
      route,
    ),
  ];
  const strategies: NativeStrategy[] = [];
  for (const s of spoke.manifest.strategies) {
    const reserveKey = new PublicKey(s.reserve),
      market = new PublicKey(s.market);
    const account = await spoke.connection.getAccountInfo(reserveKey, 'finalized');
    if (!account || !account.owner.equals(KAMINO_PROGRAM))
      throw new Error('preparation reserve unavailable/wrong owner');
    const r = Reserve.decode(account.data);
    if (
      r.version.toString() !== '1' ||
      r.lendingMarket !== s.market ||
      r.liquidity.mintPubkey !== SOLANA.asset.mint ||
      r.liquidity.mintDecimals.toString() !== '6'
    )
      throw new Error('preparation reserve mint/market mismatch');
    const marketAuthority = PublicKey.findProgramAddressSync(
      [Buffer.from('lma'), market.toBuffer()],
      KAMINO_PROGRAM,
    )[0];
    const collateralMint = new PublicKey(r.collateral.mintPubkey),
      collateral = getAssociatedTokenAddressSync(collateralMint, spoke.agent, true);
    const t = r.config.tokenInfo;
    const optional = (p: string) => (p === PublicKey.default.toBase58() ? KAMINO_PROGRAM : new PublicKey(p));
    const oracles = [
      t.pythConfiguration.price,
      t.switchboardConfiguration.priceAggregator,
      t.switchboardConfiguration.twapAggregator,
      t.scopeConfiguration.priceFeed,
    ].map(optional);
    const strategyCap = BigInt(config.strategyCaps[s.reserve] ?? '0');
    if (strategyCap <= 0n) throw new Error(`missing reviewed cap for ${s.reserve}`);
    strategies.push({
      protocol: 1,
      reserve: reserveKey,
      market,
      marketAuthority,
      liquiditySupply: new PublicKey(r.liquidity.supplyVault),
      collateralMint,
      collateral,
      oracles,
      cap: strategyCap,
      retired: false,
    });
    instructions.push(
      createAssociatedTokenAccountIdempotentInstruction(governance, collateral, spoke.agent, collateralMint),
    );
    instructions.push(
      new TransactionInstruction({
        programId: spoke.program,
        keys: [meta(spoke.agent, true), meta(governance, false, true)],
        data: Buffer.concat([
          discriminator('global:add_strategy'),
          Buffer.from([1]),
          reserveKey.toBuffer(),
          market.toBuffer(),
          marketAuthority.toBuffer(),
          new PublicKey(r.liquidity.supplyVault).toBuffer(),
          collateralMint.toBuffer(),
          collateral.toBuffer(),
          ...oracles.map((p) => p.toBuffer()),
          u64(strategyCap),
          // A new strategy is always live; only governance retires one.
          Buffer.from([0]),
        ]),
      }),
    );
  }
  const tm = new PublicKey(SOLANA.cctp.tokenMessenger);
  const tmState = await spoke.connection.getAccountInfo(pda(tm, 'token_messenger'), 'finalized');
  if (!tmState || !tmState.owner.equals(tm)) throw new Error('Circle TokenMessenger configuration unavailable');
  const tmReader = new Reader(tmState.data);
  tmReader.take(8 + 32 * 3 + 4 + 1);
  const feeRecipient = tmReader.key();
  const feeToken = getAssociatedTokenAddressSync(new PublicKey(SOLANA.asset.mint), feeRecipient, true);
  const message = Buffer.alloc(440);
  message.writeUInt32BE(6, 4);
  message.writeUInt32BE(5, 8);
  Buffer.from(getBytes(zeroPadValue(NETWORKS.base.usdc, 32))).copy(message, 152);
  const receive = receiveAccounts(spoke.agent, spoke.idle, executor, `0x${message.toString('hex')}`, feeToken).filter(
    (_k, i) => i !== 4,
  );
  const allKeys = [
    ...executeInstruction(spoke.program, spoke.agent, spoke.idle, executor, 0n, strategies, Buffer.from([0])).keys,
    ...burnAccounts(spoke.agent, spoke.idle, executor, PublicKey.default),
    ...receive,
  ];
  const addresses = [
    ...new Map(allKeys.filter((k) => !k.isSigner).map((k) => [k.pubkey.toBase58(), k.pubkey])).values(),
  ];
  const recentSlot = (await spoke.connection.getSlot('finalized')) - 1;
  const [create, lookupKey] = AddressLookupTableProgram.createLookupTable({
    authority: governance,
    payer: governance,
    recentSlot,
  });
  const lookupInstructions = [create];
  for (let at = 0; at < addresses.length; at += 20)
    lookupInstructions.push(
      AddressLookupTableProgram.extendLookupTable({
        lookupTable: lookupKey,
        authority: governance,
        payer: governance,
        addresses: addresses.slice(at, at + 20),
      }),
    );
  const serialize = (ix: TransactionInstruction) => ({
    programId: ix.programId.toBase58(),
    accounts: ix.keys.map((k) => ({ address: k.pubkey.toBase58(), isSigner: k.isSigner, isWritable: k.isWritable })),
    data: ix.data.toString('base64'),
  });
  return {
    network: SOLANA.network,
    family: SOLANA.family,
    program: spoke.program.toBase58(),
    programData: programData.toBase58(),
    upgradeAuthority: upgradeAuthority.toBase58(),
    agent: spoke.agent.toBase58(),
    idle: spoke.idle.toBase58(),
    instructions: instructions.map(serialize),
    lookupTable: {
      address: lookupKey.toBase58(),
      recentSlot,
      addresses: addresses.map((p) => p.toBase58()),
      instructions: lookupInstructions.map(serialize),
      freshness:
        'Regenerate immediately before execution: createLookupTable requires recentSlot in SlotHashes. Wait for activation/finalization before configuring SOLANA_LOOKUP_TABLES.',
    },
    note: 'Unsigned ordered instructions. initialize must additionally be signed by the recorded upgrade authority; execute it and each add_strategy through the reviewed Solana governance, then create the first checkpoint and verify readiness before Base route activation. The table covers the execute/receive path only: initialize carries eight accounts and fits a single legacy packet on its own.',
  };
}
