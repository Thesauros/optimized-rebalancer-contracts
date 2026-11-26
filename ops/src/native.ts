import type { ChainRef, InFlight, Position, TransferIndex } from './snapshot';

/** Family-neutral accounting boundary. No ethers Provider on a native spoke. */
export interface NativeSpoke {
  key: string;
  chainId: bigint;
  binding: string;
  sync(index: TransferIndex): Promise<void>;
  referenceAt(timestamp: number, ceiling?: number): Promise<ChainRef>;
  positionsAt(slot: number): Promise<Position[]>;
  sentAt(transferId: string, slot: number): Promise<InFlight>;
  referenceHash(slot: number): Promise<string>;
}

let instances: NativeSpoke[] | undefined;
export function loadNativeSpokes(): NativeSpoke[] {
  if (!process.env.CROSSCHAIN_SOLANA_MANIFEST) return [];
  if (!instances) {
    // Lazy dependency loading keeps existing EVM-only installations functional.
    const { SolanaSpoke } = require('./solana/spoke') as typeof import('./solana/spoke');
    instances = [SolanaSpoke.fromEnvironment()];
  }
  return instances;
}
