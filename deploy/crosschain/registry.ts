/**
 * Cross-chain vault network registry: the single place to describe a chain.
 *
 * Adding a network = adding one entry to NETWORKS (plus its hardhat network in
 * network-config.ts), then running the phases in docs/crosschain-deployment.md
 * for the new chain and re-running phase 2 on the chains that route to it.
 *
 * Every address below was read from this repository's deployment records or
 * checked on-chain on 2026-09-28:
 *  - USDC and CCTP V2 addresses and domains: test/forking/CctpV2Adapter.t.sol
 *    asserts `localDomain()` on the live deployments (Base 6, Arbitrum 3).
 *  - Aave/Morpho provider contracts: deployments/<network>/*.json (stateless,
 *    immutable configuration, reused as-is).
 *  - Comet addresses: ProviderManager.getYieldToken on each chain.
 */

export type Role = 'hub' | 'spoke';

export interface RouteLimits {
  /** Max amount per bridgeOut, in asset units (6 decimals for USDC). */
  maxPerTransfer: bigint;
  /** Volume bucket capacity, asset units. */
  capacity: bigint;
  /** Volume bucket refill per second, asset units. */
  refillPerSecond: bigint;
  /** Max bridge fee accepted by minReceive, in bps. */
  maxFeeBps: number;
}

export interface NetworkEntry {
  /** hardhat network name in network-config.ts */
  hardhatName: string;
  chainId: bigint;
  role: Role;
  usdc: string;
  cctp: {
    tokenMessenger: string;
    messageTransmitter: string;
    domain: number;
    /** 2000 = finalized (standard transfer), 1000 = confirmed (fast transfer). */
    minFinalityThreshold: number;
  };
  strategy: {
    name: string;
    symbol: string;
    /** Existing immutable providers reused as-is (Aave, Morpho). First entry = entry provider. */
    reusedProviders: { label: string; address: string }[];
    /** Compound V3 Comet for USDC; a fresh ProviderManager + provider are deployed for it. */
    comet?: string;
    /**
     * Per-provider cap in bps of strategy assets; label -> bps; 0 or missing = uncapped.
     * The entry provider (first reused provider) must stay uncapped: every deposit
     * lands there first, so a cap on it would make allocations revert. The executor
     * spreads funds to the capped providers by rebalancing.
     */
    capsBps: Record<string, number>;
  };
  /** Outbound route limits towards each peer chain id. */
  routes: Record<string, RouteLimits>;
  /** Confirmation depth used by off-chain services when picking reference blocks. */
  confirmations: number;
}

const CCTP_V2_TOKEN_MESSENGER = '0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d';
const CCTP_V2_MESSAGE_TRANSMITTER = '0x81D40F21F12A8F0E3252Bccb954D722d4c464B64';

const USDC = (n: number) => BigInt(n) * 1_000_000n;

const DEFAULT_ROUTE: RouteLimits = {
  maxPerTransfer: USDC(250_000),
  capacity: USDC(1_000_000),
  refillPerSecond: USDC(1_000_000) / 86_400n,
  maxFeeBps: 10,
};

export const NETWORKS: Record<string, NetworkEntry> = {
  base: {
    hardhatName: 'base',
    chainId: 8453n,
    role: 'hub',
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    cctp: {
      tokenMessenger: CCTP_V2_TOKEN_MESSENGER,
      messageTransmitter: CCTP_V2_MESSAGE_TRANSMITTER,
      domain: 6,
      minFinalityThreshold: 2000,
    },
    strategy: {
      name: 'Thesauros Cross-Chain Strategy (Base)',
      symbol: 'tcsUSDC-base',
      reusedProviders: [
        { label: 'AaveV3', address: '0xDDAA9700c0Da1020AE5dabC7AA0A0bb750DD317c' },
        { label: 'GauntletCoreMorpho', address: '0x51B8BdCdA5E41893737C9C3A08f528C97fCc1b8b' },
        { label: 'SteakhouseHighYieldMorpho', address: '0x9c35b8a92Fc3a305712b9dD8a1C34310eA09C61c' },
        { label: 'SteakhousePrimeMorpho', address: '0xDDf2C1f8EAf567c084dEE07658Ed3906029395b1' },
      ],
      comet: '0xb125E6687d4313864e53df431d5425969c15Eb2F',
      capsBps: {
        AaveV3: 0,
        CompoundV3: 5_000,
        GauntletCoreMorpho: 4_000,
        SteakhouseHighYieldMorpho: 3_000,
        SteakhousePrimeMorpho: 4_000,
      },
    },
    routes: { '42161': DEFAULT_ROUTE },
    confirmations: 10,
  },
  arbitrum: {
    hardhatName: 'arbitrum',
    chainId: 42161n,
    role: 'spoke',
    usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    cctp: {
      tokenMessenger: CCTP_V2_TOKEN_MESSENGER,
      messageTransmitter: CCTP_V2_MESSAGE_TRANSMITTER,
      domain: 3,
      minFinalityThreshold: 2000,
    },
    strategy: {
      name: 'Thesauros Cross-Chain Strategy (Arbitrum)',
      symbol: 'tcsUSDC-arb',
      reusedProviders: [
        { label: 'AaveV3', address: '0xA34574Dae6284EDc7348C36A80242b92CFBd13A5' },
        { label: 'GauntletCoreMorpho', address: '0xeB98d46937C537efF376361536D58d78c57c40d7' },
        { label: 'SteakhouseHighYieldMorpho', address: '0x6240402d3Cb33777D4E5E6B5791bC8518AEb8B99' },
        { label: 'SteakhousePrimeMorpho', address: '0x0D9FD60E25b0C3b2416D46F7dd311b0ED6743484' },
      ],
      comet: '0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf',
      capsBps: {
        AaveV3: 0,
        CompoundV3: 5_000,
        GauntletCoreMorpho: 4_000,
        SteakhouseHighYieldMorpho: 3_000,
        SteakhousePrimeMorpho: 4_000,
      },
    },
    routes: { '8453': DEFAULT_ROUTE },
    confirmations: 20,
  },
};

/** Hub-only protocol parameters (docs/epoch-benchmark.md §5). */
export const HUB_PARAMS = {
  vaultName: 'Thesauros Cross-Chain USDC',
  vaultSymbol: 'tcUSDC',
  /** Dead shares minted to the vault at initialization. */
  seedAssets: USDC(1),
  /** Seed for each strategy Rebalancer (its minAssets). */
  strategySeedAssets: USDC(1),
  accountant: {
    minTickInterval: 5n * 60n,
    maxSnapshotAge: 10n * 60n,
    maxTickAge: 2n * 3600n,
    maxTransit: 3600n,
    maxSpread: 10n ** 16n, // 1%
    depositClearingMaxDown: 10n ** 15n, // 0.1%
    maxInFlightRatio: 25n * 10n ** 16n, // 25%
    maxOverdueInFlight: 0n,
  },
  upBucket: { capacity: 5n * 10n ** 15n, refillPerSecond: (2n * 10n ** 17n) / 31_536_000n }, // 0.5%, 20% APR
  downBucket: { capacity: 2n * 10n ** 15n, refillPerSecond: 10n ** 15n / 86_400n }, // 0.2%, 0.1%/day
  epoch: { minDuration: 4n * 3600n, maxDuration: 6n * 3600n, minTicks: 1n, maxClearingDelay: 3600n },
  limits: {
    minDeposit: USDC(10),
    maxEpochDeposits: USDC(5_000_000),
    minimumBuffer: USDC(10_000),
    minBufferRatio: 5n * 10n ** 16n, // 5% of bid NAV
    maxInstantWithdrawal: USDC(10_000),
    dailyInstantLimit: USDC(50_000),
    instantFee: 10n ** 15n, // 0.1%
    instantMaxTickAge: 2n * 3600n,
  },
  fees: { management: 0n, performance: 0n },
};

/** Governance and operational identities; must be set in the environment. */
export function identities() {
  const need = (key: string) => {
    const v = process.env[key];
    if (!v) throw new Error(`${key} is not set`);
    return v;
  };
  return {
    /** Safe multisig: ADMIN_ROLE, ProxyAdmin owner, Timelock owner, treasury. */
    safe: need('CROSSCHAIN_SAFE'),
    navUpdater: need('CROSSCHAIN_NAV_UPDATER'),
    executor: need('CROSSCHAIN_EXECUTOR'),
    guardian: need('CROSSCHAIN_GUARDIAN'),
    timelockDelay: BigInt(process.env.CROSSCHAIN_TIMELOCK_DELAY ?? '86400'),
  };
}

export function hubEntry(): [string, NetworkEntry] {
  const hubs = Object.entries(NETWORKS).filter(([, n]) => n.role === 'hub');
  if (hubs.length !== 1) throw new Error('registry must contain exactly one hub');
  return hubs[0];
}

export function entryByChainId(chainId: bigint): [string, NetworkEntry] {
  const found = Object.entries(NETWORKS).find(([, n]) => n.chainId === chainId);
  if (!found) throw new Error(`chain ${chainId} is not in the cross-chain registry`);
  return found;
}

export function routeId(srcChainId: bigint, dstChainId: bigint): string {
  // stable, human-derivable id: keccak256("thesauros.route.v1:<src>-><dst>")
  const { id } = require('ethers') as typeof import('ethers');
  return id(`thesauros.route.v1:${srcChainId}->${dstChainId}`);
}
