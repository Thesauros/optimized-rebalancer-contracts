import { AccountMeta, PublicKey, SystemProgram, TransactionInstruction } from '@solana/web3.js';
import { getBytes } from 'ethers';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { checkpointPda, discriminator, NativeStrategy, seedBytes, u64, vector } from './codec';
import { KAMINO_PROGRAM, meta, strategyAdapter, TOKEN_PROGRAM } from './kamino';

const TM = new PublicKey(SOLANA.cctp.tokenMessenger),
  MT = new PublicKey(SOLANA.cctp.messageTransmitter);
export const LOADER_PROGRAM = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');
export const pda = (program: PublicKey, name: string, ...seeds: Uint8Array[]): PublicKey =>
  PublicKey.findProgramAddressSync([Buffer.from(name), ...seeds.map((s) => Buffer.from(s))], program)[0];

/** ProgramData of an upgradeable program; carries the deploy authority that
 * `initialize` requires as a signer. */
export const programDataAddress = (program: PublicKey): PublicKey =>
  PublicKey.findProgramAddressSync([program.toBuffer()], LOADER_PROGRAM)[0];

export function executeInstruction(
  program: PublicKey,
  agent: PublicKey,
  idle: PublicKey,
  payer: PublicKey,
  sequence: bigint,
  strategies: NativeStrategy[],
  actionData: Buffer,
  prefix: AccountMeta[] = [],
): TransactionInstruction {
  const checkpoint = checkpointPda(program, agent, sequence);
  // The program skips a retired strategy's reserve entirely, so the observation
  // tail carries seven accounts per live strategy and nothing for a retired one.
  const live = strategies.filter((s) => !s.retired);
  return new TransactionInstruction({
    programId: program,
    keys: [
      meta(agent, true),
      meta(idle, true),
      meta(payer, true, true),
      meta(checkpoint, true),
      meta(SystemProgram.programId),
      ...prefix,
      ...live.flatMap((s) => strategyAdapter(s).observationAccounts(s)),
      meta(KAMINO_PROGRAM),
    ],
    data: Buffer.concat([discriminator('global:execute'), actionData]),
  });
}

/** Deploy-time accounts. `initialize` reads the upgrade authority out of
 * `programData` and requires it to sign, so publishing the seed is not enough
 * to claim the agent PDA. */
export function initializeInstruction(
  program: PublicKey,
  agent: PublicKey,
  idle: PublicKey,
  programData: PublicKey,
  upgradeAuthority: PublicKey,
  governance: PublicKey,
  seed: string,
  executor: PublicKey,
  guardian: PublicKey,
  route: Buffer,
): TransactionInstruction {
  return new TransactionInstruction({
    programId: program,
    keys: [
      meta(agent, true),
      meta(programData),
      meta(upgradeAuthority, false, true),
      meta(governance, true, true),
      meta(idle, true),
      meta(new PublicKey(SOLANA.asset.mint)),
      meta(TOKEN_PROGRAM),
      meta(SystemProgram.programId),
    ],
    data: Buffer.concat([
      discriminator('global:initialize'),
      seedBytes(seed),
      executor.toBuffer(),
      guardian.toBuffer(),
      route,
    ]),
  });
}

/** Governance-only. `collateral` is the retiring strategy's own cToken account;
 * the program requires its balance to be exactly zero. */
export function retireStrategyInstruction(
  program: PublicKey,
  agent: PublicKey,
  collateral: PublicKey,
  governance: PublicKey,
  index: number,
): TransactionInstruction {
  if (!Number.isInteger(index) || index < 0 || index > 7) throw new Error('invalid strategy index');
  return new TransactionInstruction({
    programId: program,
    keys: [meta(agent, true), meta(collateral), meta(governance, false, true)],
    data: Buffer.concat([discriminator('global:retire_strategy'), Buffer.from([index])]),
  });
}

export function allocateData(index: number, amount: bigint, minimum: bigint, deposit: boolean): Buffer {
  if (!Number.isInteger(index) || index < 0 || index > 7 || amount <= 0n || minimum <= 0n)
    throw new Error('invalid strategy operation');
  return Buffer.concat([Buffer.from([deposit ? 1 : 2, index]), u64(amount), u64(minimum)]);
}

export function burnAccounts(agent: PublicKey, idle: PublicKey, payer: PublicKey, event: PublicKey): AccountMeta[] {
  const domain = Buffer.from('6');
  return [
    meta(agent),
    meta(payer, true, true),
    meta(pda(TM, 'sender_authority')),
    meta(idle, true),
    meta(pda(TM, 'denylist_account', agent.toBytes())),
    meta(pda(MT, 'message_transmitter'), true),
    meta(pda(TM, 'token_messenger')),
    meta(pda(TM, 'remote_token_messenger', domain)),
    meta(pda(TM, 'token_minter')),
    meta(pda(TM, 'local_token', new PublicKey(SOLANA.asset.mint).toBytes()), true),
    meta(new PublicKey(SOLANA.asset.mint), true),
    meta(event, true, true),
    meta(MT),
    meta(TM),
    meta(TOKEN_PROGRAM),
    meta(SystemProgram.programId),
    meta(pda(TM, '__event_authority')),
    meta(TM),
    meta(TM),
  ];
}
export function bridgeData(amount: bigint, minReceive: bigint): Buffer {
  if (amount <= 0n || minReceive <= 0n || minReceive > amount) throw new Error('invalid bridge amount');
  return Buffer.concat([Buffer.from([3]), u64(amount), u64(minReceive)]);
}

export function receiveData(message: string, attestation: string): Buffer {
  const msg = Buffer.from(getBytes(message));
  if (msg.length !== 440 || getBytes(attestation).length === 0) throw new Error('invalid CCTP payload');
  return Buffer.concat([Buffer.from([4]), vector(msg), vector(getBytes(attestation))]);
}
export function receiveAccounts(
  agent: PublicKey,
  idle: PublicKey,
  payer: PublicKey,
  message: string,
  feeRecipientTokenAccount: PublicKey,
): AccountMeta[] {
  const b = Buffer.from(getBytes(message));
  if (b.length !== 440 || b.readUInt32BE(4) !== 6 || b.readUInt32BE(8) !== 5) throw new Error('wrong CCTP direction');
  const domain = Buffer.from('6'),
    mint = new PublicKey(SOLANA.asset.mint);
  return [
    meta(payer, true, true),
    meta(agent),
    meta(pda(MT, 'message_transmitter_authority', TM.toBytes())),
    meta(pda(MT, 'message_transmitter')),
    meta(pda(MT, 'used_nonce', b.subarray(12, 44)), true),
    meta(TM),
    meta(SystemProgram.programId),
    meta(pda(MT, '__event_authority')),
    meta(MT),
    meta(pda(TM, 'token_messenger')),
    meta(pda(TM, 'remote_token_messenger', domain)),
    meta(pda(TM, 'token_minter'), true),
    meta(pda(TM, 'local_token', mint.toBytes()), true),
    meta(pda(TM, 'token_pair', domain, b.subarray(152, 184))),
    meta(feeRecipientTokenAccount, true),
    meta(idle, true),
    meta(pda(TM, 'custody', mint.toBytes()), true),
    meta(TOKEN_PROGRAM),
    meta(pda(TM, '__event_authority')),
    meta(TM),
    meta(MT),
  ];
}
