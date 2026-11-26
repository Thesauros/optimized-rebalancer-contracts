/**
 * Strategy (Rebalancer) valuation that keeps working while a provider view fails.
 *
 * Since the complete-NAV remediation, `Rebalancer.totalAssets()` reverts
 * `ProviderUnavailable` while any provider's balance view fails, and so does
 * everything built on it: `convertToAssets`, `previewRedeem`, `getAccruedFees`,
 * deposits and exits. Settlement must never price from an incomplete total, but
 * the services still need a number: NAV keeps committing Ticks with such a
 * position at its readable lower bound (docs/nav-reproduction.md), the monitor
 * names the failing provider, the API shows the rest. Before this module NAV
 * called `convertToAssets` first, so one failing view on one chain stopped every
 * Tick of the vault.
 *
 * The bound is the contract's own arithmetic on public getters:
 *   - `_safeGetDepositBalance`: a provider counts only if its source is pinned,
 *     `getSource` returns the pinned source and `getDepositBalance` answers, each
 *     within PROVIDER_VIEW_CALL_GAS; otherwise it counts as 0;
 *   - `_accruedFees` and `_convertToAssetsWithTotals`, rounding included.
 * With every provider readable it equals `convertToAssets`
 * (test/unit/ReadableStrategyValue.t.sol fuzzes that identity).
 *
 * Implementations deployed before the remediation (the live Base and Arbitrum
 * strategies as of 2026-11-07) have neither the revert nor the getters: their
 * `convertToAssets` already counts a failing provider as 0, and is used as is.
 *
 * Only a provider view that demonstrably reverted (or ran out of its gas) counts
 * as failing. Any other RPC error propagates: a rate limit must never be priced
 * as a missing provider.
 */
import { Contract, Provider, ZeroAddress, id, isError } from 'ethers';
import { ERC20, PROVIDER } from './abi';
import { isTransient } from './util';

/** Rebalancer.PROVIDER_VIEW_CALL_GAS: the gas each provider view gets. */
export const PROVIDER_VIEW_CALL_GAS = 3_000_000n;
/** eth_call limit giving a provider view that budget: the stipend plus the call's intrinsic gas. */
const VIEW_CALL_LIMIT = PROVIDER_VIEW_CALL_GAS + 30_000n;
const SCALE = 10n ** 18n;
const YEAR = 365n * 24n * 60n * 60n;
const PROVIDER_UNAVAILABLE = id('ProviderUnavailable()').slice(0, 10);
const REVERTED = /revert|out of gas|invalid opcode|stack (?:underflow|overflow)/i;

/** The strategy's fee inputs at one block (public getters plus that block's time). */
export interface FeeState {
  managementFee: bigint;
  performanceFee: bigint;
  highWaterMark: bigint;
  lastTimestamp: bigint;
  /** block.timestamp of the block read */
  now: bigint;
  /** totalSupply() */
  supply: bigint;
}

const mulDiv = (a: bigint, b: bigint, c: bigint) => (a * b) / c;
const mulDivUp = (a: bigint, b: bigint, c: bigint) => (a * b + c - 1n) / c;

/** `Rebalancer._accruedFees`: [performanceFeeShares, managementFeeShares]. */
export function accruedFeeShares(totalManagedAssets: bigint, f: FeeState): [bigint, bigint] {
  if (f.highWaterMark === 0n) throw new Error('SecurityAccountingNotInitialized');
  const t = totalManagedAssets;
  if (t === 0n || f.supply === 0n) return [0n, 0n];
  if (f.now < f.lastTimestamp) throw new Error(`block time ${f.now} precedes the strategy's fee time ${f.lastTimestamp}`);
  let management = mulDiv(t, f.managementFee * (f.now - f.lastTimestamp), YEAR * SCALE);
  if (management >= t) management = t - 1n;
  const highWaterAssets = mulDivUp(f.highWaterMark, f.supply, SCALE);
  let performance = 0n;
  if (t - management > highWaterAssets && f.performanceFee !== 0n) {
    performance = mulDiv(t - management - highWaterAssets, f.performanceFee, SCALE);
  }
  if (performance >= t - management) performance = t - management - 1n;
  const net = t - management - performance;
  return [mulDiv(performance, f.supply, net), mulDiv(management, f.supply, net)];
}

/** `Rebalancer._convertToAssets` over a given total, rounding down. */
export function sharesToAssets(shares: bigint, totalManagedAssets: bigint, f: FeeState): bigint {
  const [performance, management] = accruedFeeShares(totalManagedAssets, f);
  const supply = f.supply + performance + management;
  return supply === 0n ? shares : mulDiv(shares, totalManagedAssets, supply);
}

/**
 * True when an eth_call reverted or ran out of gas, as opposed to failing in
 * transport. ethers turns every JSON-RPC error of an eth_call into CALL_EXCEPTION,
 * a rate limit included, and its own message always says "missing revert data";
 * so only two things count: revert data (ethers extracts it, even "0x", only from
 * a node error that reports a revert) or the node's own message.
 */
export function reverted(e: unknown): boolean {
  if (!isError(e, 'CALL_EXCEPTION')) return false;
  if (typeof e.data === 'string') return true;
  const node = String((e as any).info?.error?.message ?? '');
  return REVERTED.test(node) && !isTransient(node);
}

function providerOf(strategy: Contract): Provider {
  const runner = strategy.runner as any;
  return (runner?.provider ?? runner) as Provider;
}

export interface ReadableTotal {
  /** the strategy's idle asset plus every provider that answers */
  total: bigint;
  /** providers left out: a view reverted or the source is not the pinned one */
  failing: string[];
}

/**
 * `Rebalancer._totalAssetsWithHealth` on public getters, at one block, plus which
 * providers failed. On an implementation without source pinning the source check
 * is skipped.
 */
export async function readableTotalAssets(strategy: Contract, blockTag: number): Promise<ReadableTotal> {
  const at = { blockTag };
  const self = await strategy.getAddress();
  const asset: string = await strategy.asset(at);
  let total = BigInt(await new Contract(asset, ERC20, strategy.runner).balanceOf(self, at));
  const failing: string[] = [];
  for (const p of (await strategy.getProviders(at)) as string[]) {
    const balance = await providerBalance(strategy, p, asset, self, blockTag);
    if (balance === undefined) failing.push(p);
    else total += balance;
  }
  return { total, failing };
}

async function providerBalance(strategy: Contract, p: string, asset: string, self: string, blockTag: number): Promise<bigint | undefined> {
  let pinned: string | undefined;
  try {
    pinned = await strategy.getPinnedProviderSource(p, { blockTag });
  } catch (e) {
    if (!reverted(e)) throw e;
    pinned = undefined; // implemented before source pinning
  }
  if (pinned === ZeroAddress) return undefined;
  const provider = new Contract(p, PROVIDER, strategy.runner);
  const call = { blockTag, gasLimit: VIEW_CALL_LIMIT };
  try {
    if (pinned !== undefined) {
      const source: string = await provider.getSource(asset, self, ZeroAddress, call);
      if (source.toLowerCase() !== pinned.toLowerCase()) return undefined;
    }
    return BigInt(await provider.getDepositBalance(self, self, call));
  } catch (e) {
    if (reverted(e)) return undefined;
    throw e;
  }
}

/** The fee inputs of `_accruedFees` at one block. */
export async function feeState(strategy: Contract, blockTag: number): Promise<FeeState> {
  const at = { blockTag };
  const block = await providerOf(strategy).getBlock(blockTag);
  if (!block) throw new Error(`block ${blockTag} not found`);
  return {
    managementFee: BigInt(await strategy.getManagementFee(at)),
    performanceFee: BigInt(await strategy.getPerformanceFee(at)),
    highWaterMark: BigInt(await strategy.getHighWaterMark(at)),
    lastTimestamp: BigInt(await strategy.getLastTimestamp(at)),
    now: BigInt(block.timestamp),
    supply: BigInt(await strategy.totalSupply(at)),
  };
}

export interface ShareValue {
  /** false while any provider's balance view fails */
  healthy: boolean;
  /**
   * The strategy itself refuses conversions, deposits and exits until the view
   * answers again (implementations with the complete-NAV rule). False on a
   * healthy strategy and on implementations that price from the readable
   * providers themselves.
   */
  blocked: boolean;
  /** convertToAssets(shares); while a view fails, the readable lower bound */
  value: bigint;
  /** what the bound counted, when the strategy is blocked */
  readable?: ReadableTotal;
}

/** The value of `shares` of `strategy` at `blockTag`, also while a provider view fails. */
export async function strategyShareValue(strategy: Contract, shares: bigint, blockTag: number): Promise<ShareValue> {
  const at = { blockTag };
  const healthy: boolean = await strategy.providersHealthy(at);
  if (healthy) return { healthy, blocked: false, value: BigInt(await strategy.convertToAssets(shares, at)) };
  try {
    // implementations before the complete-NAV rule count the failing provider as 0 themselves
    return { healthy, blocked: false, value: BigInt(await strategy.convertToAssets(shares, at)) };
  } catch (e) {
    // ProviderUnavailable(); an RPC that strips revert data leaves only "execution reverted"
    const data = isError(e, 'CALL_EXCEPTION') && typeof e.data === 'string' && e.data.length > 2 ? e.data : undefined;
    if (!reverted(e) || (data !== undefined && !data.startsWith(PROVIDER_UNAVAILABLE))) throw e;
  }
  const readable = await readableTotalAssets(strategy, blockTag);
  return { healthy, blocked: true, value: sharesToAssets(shares, readable.total, await feeState(strategy, blockTag)), readable };
}
