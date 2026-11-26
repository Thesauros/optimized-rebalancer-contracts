import { Connection, PublicKey, AccountMeta, SYSVAR_INSTRUCTIONS_PUBKEY } from '@solana/web3.js';
import { address, createSolanaRpc } from '@solana/kit';
import Decimal from 'decimal.js';
import { Reserve } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/Reserve';
import { LendingMarket } from '@kamino-finance/klend-sdk/dist/@codegen/klend/accounts/LendingMarket';
import { KaminoReserve } from '@kamino-finance/klend-sdk/dist/classes/reserve';
import type { LedgerInstant } from '@kamino-finance/klend-sdk/dist/utils/ledger';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { NativeStrategy } from './codec';

export const TOKEN_PROGRAM = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
export const KAMINO_PROGRAM = new PublicKey(SOLANA.strategies[0].program);
export const meta = (pubkey: PublicKey, isWritable = false, isSigner = false): AccountMeta => ({
  pubkey,
  isWritable,
  isSigner,
});

export interface SolanaStrategyAdapter {
  protocol: string;
  executionAccounts(agent: PublicKey, idle: PublicKey, strategy: NativeStrategy, deposit: boolean): AccountMeta[];
  observationAccounts(strategy: NativeStrategy): AccountMeta[];
  read(connection: Connection, agent: PublicKey, strategy: NativeStrategy): Promise<KaminoPosition>;
}
export interface KaminoPosition {
  family: 'solana';
  network: string;
  protocol: string;
  reserve: string;
  slot: number;
  collateralUnits: bigint;
  value: bigint;
  supplyApr: number;
  supplyApy: number;
  reserveRewardsApr: number;
  freelyAvailableLiquidity: bigint;
}

export function tokenAmount(data: Buffer, mint: PublicKey, authority: PublicKey): bigint {
  if (
    data.length !== 165 ||
    !new PublicKey(data.subarray(0, 32)).equals(mint) ||
    !new PublicKey(data.subarray(32, 64)).equals(authority) ||
    data[108] !== 1 ||
    data.readUInt32LE(72) !== 0 ||
    data.readUInt32LE(129) !== 0
  )
    throw new Error('invalid strategy token custody');
  return data.readBigUInt64LE(64);
}

export function valueFromReserve(state: Reserve, units: bigint): bigint {
  if (units < 0n) throw new Error('negative collateral');
  const l = state.liquidity,
    sf = 1n << 60n;
  const net =
    BigInt(l.totalAvailableAmount.toString()) * sf +
    BigInt(l.borrowedAmountSf.toString()) -
    BigInt(l.accumulatedProtocolFeesSf.toString()) -
    BigInt(l.accumulatedReferrerFeesSf.toString()) -
    BigInt(l.pendingReferrerFeesSf.toString());
  const supply = BigInt(state.collateral.mintTotalSupply.toString());
  if (net < 0n || (units > 0n && supply === 0n)) throw new Error('invalid reserve exchange rate');
  return units === 0n ? 0n : (units * net) / supply / sf;
}
export function collateralForAssets(state: Reserve, assets: bigint): bigint {
  if (assets <= 0n) throw new Error('assets must be positive');
  const l = state.liquidity,
    sf = 1n << 60n;
  const net =
    BigInt(l.totalAvailableAmount.toString()) * sf +
    BigInt(l.borrowedAmountSf.toString()) -
    BigInt(l.accumulatedProtocolFeesSf.toString()) -
    BigInt(l.accumulatedReferrerFeesSf.toString()) -
    BigInt(l.pendingReferrerFeesSf.toString());
  if (net <= 0n) throw new Error('reserve has no net supply');
  return (assets * BigInt(state.collateral.mintTotalSupply.toString()) * sf + net - 1n) / net;
}

export const kaminoAdapter: SolanaStrategyAdapter = {
  protocol: 'kamino-lending',
  executionAccounts(agent, idle, s, deposit) {
    const keys = deposit
      ? [
          agent,
          s.reserve,
          s.market,
          s.marketAuthority,
          new PublicKey(SOLANA.asset.mint),
          s.liquiditySupply,
          s.collateralMint,
          idle,
          s.collateral,
          TOKEN_PROGRAM,
          TOKEN_PROGRAM,
          SYSVAR_INSTRUCTIONS_PUBKEY,
        ]
      : [
          agent,
          s.market,
          s.reserve,
          s.marketAuthority,
          new PublicKey(SOLANA.asset.mint),
          s.collateralMint,
          s.liquiditySupply,
          s.collateral,
          idle,
          TOKEN_PROGRAM,
          TOKEN_PROGRAM,
          SYSVAR_INSTRUCTIONS_PUBKEY,
        ];
    const writable = deposit ? [1, 5, 6, 7, 8] : [2, 5, 6, 7, 8];
    // The PDA is signed only inside the agent CPI, never in the outer transaction.
    return [...keys.map((p, i) => meta(p, writable.includes(i))), meta(KAMINO_PROGRAM)];
  },
  observationAccounts(s) {
    return [meta(s.reserve, true), meta(s.market), meta(s.collateral), ...s.oracles.map((o) => meta(o))];
  },
  async read(connection, agent, s) {
    const { context, value: accounts } = await connection.getMultipleAccountsInfoAndContext(
      [s.reserve, s.market, s.collateral],
      'finalized',
    );
    if (accounts.some((a) => !a)) throw new Error('Kamino account unavailable');
    if (
      !accounts[0]!.owner.equals(KAMINO_PROGRAM) ||
      !accounts[1]!.owner.equals(KAMINO_PROGRAM) ||
      !accounts[2]!.owner.equals(TOKEN_PROGRAM)
    )
      throw new Error('Kamino account owner mismatch');
    const reserve = Reserve.decode(accounts[0]!.data),
      market = LendingMarket.decode(accounts[1]!.data);
    if (
      reserve.version.toString() !== '1' ||
      reserve.lendingMarket !== s.market.toBase58() ||
      reserve.liquidity.mintPubkey !== SOLANA.asset.mint ||
      reserve.liquidity.mintDecimals.toString() !== '6' ||
      reserve.collateral.mintPubkey !== s.collateralMint.toBase58() ||
      reserve.liquidity.supplyVault !== s.liquiditySupply.toBase58()
    )
      throw new Error('Kamino reserve/mint binding mismatch');
    const units = tokenAmount(accounts[2]!.data, s.collateralMint, agent);
    return reserveMetrics(connection, s.reserve, reserve, market, context.slot, units);
  },
};

export async function reserveMetrics(
  connection: Connection,
  reserveKey: PublicKey,
  reserve: Reserve,
  market: LendingMarket,
  slot: number,
  units: bigint,
): Promise<KaminoPosition> {
  const blockTime = await connection.getBlockTime(slot);
  if (blockTime === null) throw new Error('Kamino reference time unavailable');
  const samples = await connection.getRecentPerformanceSamples(1);
  if (!samples[0] || samples[0].numSlots < 1 || samples[0].samplePeriodSecs < 1)
    throw new Error('Solana slot duration unavailable');
  const slotMs = (samples[0].samplePeriodSecs * 1000) / samples[0].numSlots;
  const price = new Decimal(reserve.liquidity.marketPriceSf.toString()).div(new Decimal(2).pow(60));
  const rpc = createSolanaRpc(connection.rpcEndpoint);
  const sdk = new KaminoReserve(
    reserve,
    address(reserveKey.toBase58()),
    {
      mintAddress: address(SOLANA.asset.mint),
      decimals: new Decimal(6),
      price,
      timestamp: BigInt(reserve.liquidity.marketPriceLastUpdatedTs.toString()),
      valid: price.gt(0),
    },
    rpc,
    slotMs,
    market.reserveRewardsMaxAprBps,
  );
  const instant = { slot: BigInt(slot), blockTime: BigInt(blockTime) } as LedgerInstant;
  const apr = sdk.calculateSupplyAPR(instant, market.referralFeeBps);
  const apy = sdk.totalSupplyAPY(instant);
  const rewardApr = sdk.calculateEffectiveReserveRewardsSupplyAPR(instant, market.referralFeeBps);
  if (![apr, apy, rewardApr].every(Number.isFinite) || apr < 0 || apy < 0 || rewardApr < 0)
    throw new Error('Kamino returned invalid yield');
  return {
    family: 'solana',
    network: SOLANA.network,
    protocol: 'kamino-lending',
    reserve: reserveKey.toBase58(),
    slot,
    collateralUnits: units,
    value: BigInt(
      sdk
        .cTokensToLiquidity(new Decimal(units.toString()), instant, undefined, market.referralFeeBps)
        .floor()
        .toFixed(0),
    ),
    supplyApr: apr,
    supplyApy: apy,
    reserveRewardsApr: rewardApr,
    freelyAvailableLiquidity: BigInt(
      sdk.getFreelyAvailableLiquidityAmount(instant, market.referralFeeBps).floor().toFixed(0),
    ),
  };
}

/** Rate discovery works before custody deployment and requires no wallet. */
export async function readKaminoRates(connection: Connection, reserveKey: PublicKey, marketKey: PublicKey) {
  if ((await connection.getGenesisHash()) !== SOLANA.genesisHash) throw new Error('rate RPC is not Solana mainnet');
  const { context, value: accounts } = await connection.getMultipleAccountsInfoAndContext(
    [reserveKey, marketKey],
    'finalized',
  );
  if (accounts.some((a) => !a || !a.owner.equals(KAMINO_PROGRAM)))
    throw new Error('Kamino rate source unavailable/wrong owner');
  const reserve = Reserve.decode(accounts[0]!.data),
    market = LendingMarket.decode(accounts[1]!.data);
  if (
    reserve.lendingMarket !== marketKey.toBase58() ||
    reserve.liquidity.mintPubkey !== SOLANA.asset.mint ||
    reserve.liquidity.mintDecimals.toString() !== '6'
  )
    throw new Error('Kamino rate source mint/market mismatch');
  const { collateralUnits, value, ...rates } = await reserveMetrics(
    connection,
    reserveKey,
    reserve,
    market,
    context.slot,
    0n,
  );
  return rates;
}

const adapters = new Map<number, SolanaStrategyAdapter>([[1, kaminoAdapter]]);
export function strategyAdapter(s: NativeStrategy): SolanaStrategyAdapter {
  const adapter = adapters.get(s.protocol);
  if (!adapter) throw new Error(`unsupported Solana strategy protocol ${s.protocol}`);
  return adapter;
}
