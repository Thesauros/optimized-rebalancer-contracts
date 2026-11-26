/** Native chain registry: never passed to ethers providers or Hardhat. */
export const SOLANA = {
  family: 'solana' as const,
  key: 'solana',
  role: 'spoke' as const,
  network: 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp',
  genesisHash: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
  accountingId: 0x8000000000000005n,
  asset: { symbol: 'USDC', decimals: 6, mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v' },
  cctp: {
    domain: 5,
    minFinalityThreshold: 2000,
    tokenMessenger: 'CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe',
    messageTransmitter: 'CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC',
  },
  strategies: [
    {
      protocol: 'kamino-lending' as const,
      program: 'KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD',
      market: '7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF',
      reserve: 'D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59',
    },
  ],
};

export interface SolanaManifest {
  family: 'solana';
  network: typeof SOLANA.network;
  program: string;
  /** SHA-256 of deployed ProgramData bytes after the 45-byte loader header. */
  programDataSha256?: string;
  /** Seed is a 32-byte hex string; all PDAs are re-derived at startup. */
  seed: string;
  agent: string;
  idle: string;
  /** Base's IBridgeAdapter implementation, not its EVM-to-EVM adapter. */
  hubAdapter: string;
  hubAgent: string;
  maxCheckpointAgeSeconds: number;
  /** Explicit opt-in for a local validator only, never devnet mainnet mixing. */
  localValidator?: boolean;
  /** Required with localValidator; prevents caches/journals crossing forks. */
  genesisHash?: string;
  strategies: { protocol: 'kamino-lending'; reserve: string; market: string }[];
}
