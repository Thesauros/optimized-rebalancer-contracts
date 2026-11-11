import fs from 'node:fs';
import path from 'node:path';
import bs58 from 'bs58';
import {
  ComputeBudgetProgram,
  Keypair,
  TransactionInstruction,
  TransactionMessage,
  VersionedTransaction,
} from '@solana/web3.js';
import type { SolanaSpoke } from './spoke';
import { semaphore } from '../util';
import { setTimeout as delay } from 'node:timers/promises';

export const nativeWriteGate = semaphore(1);
type JournalRecord = {
  binding: string;
  signature: string;
  transaction: string;
  blockhash: string;
  lastValidBlockHeight: number;
};
export function solanaSigner(role = 'SOLANA_EXECUTOR_KEYPAIR'): Keypair {
  const file = process.env[role];
  if (!file) throw new Error(`${role} must name a Solana JSON keypair file`);
  const key = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(key) || key.length !== 64 || key.some((n) => !Number.isInteger(n) || n < 0 || n > 255))
    throw new Error('invalid Solana keypair file');
  return Keypair.fromSecretKey(Uint8Array.from(key));
}

/** Journal signed bytes before broadcast. A retry of the same operation sends
 * the same signature; an ambiguous expiry requires reconciliation, never a new burn. */
export async function sendNative(
  spoke: SolanaSpoke,
  instructions: TransactionInstruction[],
  payer: Keypair,
  additional: Keypair[],
  operation: string,
  send: boolean,
): Promise<string> {
  if (!/^[a-zA-Z0-9-]+$/.test(operation)) throw new Error('invalid operation journal name');
  const dir = process.env.SOLANA_TX_JOURNAL_DIR;
  const file = dir ? path.join(dir, `${spoke.agent.toBase58()}-${operation}.json`) : undefined;
  // Reconcile a previous signature before building/simulating against state
  // that the previous transaction may already have changed.
  if (send && file && fs.existsSync(file)) return deliverJournal(spoke, JSON.parse(fs.readFileSync(file, 'utf8')));
  const latest = await spoke.connection.getLatestBlockhash('finalized');
  const luts = [];
  for (const key of (process.env.SOLANA_LOOKUP_TABLES ?? '').split(',').filter(Boolean)) {
    const { PublicKey } = await import('@solana/web3.js');
    const table = await spoke.connection.getAddressLookupTable(new PublicKey(key));
    if (!table.value) throw new Error(`lookup table unavailable: ${key}`);
    luts.push(table.value);
  }
  const tx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: payer.publicKey,
      recentBlockhash: latest.blockhash,
      instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_200_000 }), ...instructions],
    }).compileToV0Message(luts),
  );
  tx.sign([payer, ...additional]);
  if (tx.serialize().length > 1232)
    throw new Error(
      'Solana transaction exceeds 1232 bytes; prepare/activate SOLANA_LOOKUP_TABLES for the registered strategies and CCTP',
    );
  const simulation = await spoke.connection.simulateTransaction(tx, { sigVerify: true, commitment: 'finalized' });
  if (simulation.value.err)
    throw new Error(
      `Solana simulation failed: ${JSON.stringify(simulation.value.err)}; ${(simulation.value.logs ?? []).join('\n')}`,
    );
  if (!send) return 'simulated';
  if (!dir || !file) throw new Error('set durable SOLANA_TX_JOURNAL_DIR before broadcasting');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const record: JournalRecord = {
    binding: spoke.binding,
    signature: bs58.encode(tx.signatures[0]),
    transaction: Buffer.from(tx.serialize()).toString('base64'),
    ...latest,
  };
  fs.writeFileSync(file, JSON.stringify(record), { flag: 'wx', mode: 0o600 });
  return deliverJournal(spoke, record);
}

async function deliverJournal(spoke: SolanaSpoke, record: JournalRecord): Promise<string> {
  if (record.binding !== spoke.binding) throw new Error('native transaction journal deployment mismatch');
  const status = (await spoke.connection.getSignatureStatuses([record.signature], { searchTransactionHistory: true }))
    .value[0];
  if (status?.err) throw new Error(`previous native transaction failed: ${JSON.stringify(status.err)}`);
  if (status?.confirmationStatus === 'finalized') return record.signature;
  if ((await spoke.connection.getBlockHeight('finalized')) > record.lastValidBlockHeight)
    throw new Error(`native transaction expired; reconcile ${record.signature} before replacing its journal`);
  const signature = await spoke.sender.sendRawTransaction(Buffer.from(record.transaction, 'base64'), {
    skipPreflight: false,
    maxRetries: 3,
  });
  if (signature !== record.signature) throw new Error('RPC returned unexpected native signature');
  for (let attempt = 0; attempt < 30; attempt++) {
    const confirmation = (await spoke.connection.getSignatureStatuses([signature], { searchTransactionHistory: true }))
      .value[0];
    if (confirmation?.err) throw new Error(`native transaction failed: ${JSON.stringify(confirmation.err)}`);
    if (confirmation?.confirmationStatus === 'finalized') return signature;
    await delay(2000);
  }
  throw new Error(`native transaction pending: ${signature}; retry will reconcile the existing journal`);
}
