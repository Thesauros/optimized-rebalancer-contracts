import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, Contract, Interface, getAddress, id, makeError, toBeHex, zeroPadValue } from 'ethers';
import { CHAIN_AGENT, ERC20, PROVIDER, STRATEGY } from '../src/abi';
import { KIND_STRATEGY_SHARES, positionKey, positionsAt } from '../src/snapshot';
import { FeeState, PROVIDER_VIEW_CALL_GAS, accruedFeeShares, readableTotalAssets, sharesToAssets, strategyShareValue } from '../src/strategy-value';

const addr = (n: number) => getAddress(zeroPadValue(toBeHex(n), 20));
const USDC = addr(0xc0);
const STRAT = addr(0x57);
const AGENT = addr(0xa9);
const A = addr(0xa1); // provider A, source SRC_A
const B = addr(0xb1); // provider B, source SRC_B
const SRC_A = addr(0x5a);
const SRC_B = addr(0x5b);
const BLOCK = 1234;
const PROVIDER_UNAVAILABLE = id('ProviderUnavailable()').slice(0, 10);

/**
 * The scenario of test/unit/ReadableStrategyValue.t.sol `testGoldenVectors`:
 * 2% management and 20% performance fee, 30 days, 50 USDC of yield on A; then
 * provider B (400 USDC) stops answering. The numbers are the contract's.
 */
const GOLDEN: FeeState = {
  managementFee: 2n * 10n ** 16n,
  performanceFee: 2n * 10n ** 17n,
  highWaterMark: 10n ** 18n,
  lastTimestamp: 1n,
  now: 2_592_001n,
  supply: 1_001_000_000n,
};
const SHARES = 1_000_000_000n;

/** A revert as JsonRpcProvider reports it: revert data present (possibly "0x"). */
function revert(data: string) {
  return AbiCoder.getBuiltinCallException('call', { to: STRAT, data: '0x' }, data);
}

/** An eth_call JSON-RPC error without revert data, e.g. a rate limit or an out-of-gas. */
function rpcError(message: string) {
  const e = AbiCoder.getBuiltinCallException('call', { to: STRAT, data: '0x' }, null);
  (e as any).info = { error: { code: -32000, message } };
  return e;
}

type Handler = (args: any[]) => unknown;

/** Answers eth_call from per-address handlers, like a node would; records every call. */
class FakeChain {
  readonly calls: { to: string; fn: string; blockTag: unknown; gasLimit: unknown }[] = [];
  private readonly contracts = new Map<string, { iface: Interface; fns: Record<string, Handler> }>();
  readonly provider = this;

  add(address: string, abi: readonly string[], fns: Record<string, Handler>) {
    this.contracts.set(address.toLowerCase(), { iface: new Interface(abi), fns });
    return this;
  }

  async call(tx: any): Promise<string> {
    const c = this.contracts.get(String(tx.to).toLowerCase());
    if (!c) throw new Error(`no contract at ${tx.to}`);
    const fragment = c.iface.getFunction(String(tx.data).slice(0, 10))!;
    this.calls.push({ to: String(tx.to).toLowerCase(), fn: fragment.name, blockTag: tx.blockTag, gasLimit: tx.gasLimit });
    const handler = c.fns[fragment.name];
    if (!handler) throw revert('0x'); // a function the contract does not have
    const out = handler([...c.iface.decodeFunctionData(fragment, tx.data)]);
    return c.iface.encodeFunctionResult(fragment, [out]);
  }

  async getBlock(blockTag: unknown) {
    return { number: blockTag, timestamp: Number(GOLDEN.now) };
  }

  called(fn: string) {
    return this.calls.filter((c) => c.fn === fn);
  }
}

/** The golden strategy after B's view broke, on the current Rebalancer. */
function currentStrategy(over: { a?: Partial<Record<string, Handler>>; b?: Partial<Record<string, Handler>>; strategy?: Partial<Record<string, Handler>> } = {}) {
  return new FakeChain()
    .add(USDC, ERC20, { balanceOf: () => 0n })
    .add(STRAT, STRATEGY, {
      providersHealthy: () => false,
      convertToAssets: () => {
        throw revert(PROVIDER_UNAVAILABLE);
      },
      totalAssets: () => {
        throw revert(PROVIDER_UNAVAILABLE);
      },
      asset: () => USDC,
      getProviders: () => [A, B],
      getPinnedProviderSource: ([p]) => (p.toLowerCase() === A.toLowerCase() ? SRC_A : SRC_B),
      getManagementFee: () => GOLDEN.managementFee,
      getPerformanceFee: () => GOLDEN.performanceFee,
      getHighWaterMark: () => GOLDEN.highWaterMark,
      getLastTimestamp: () => GOLDEN.lastTimestamp,
      totalSupply: () => GOLDEN.supply,
      balanceOf: () => SHARES,
      ...over.strategy,
    })
    .add(A, PROVIDER, { getSource: () => SRC_A, getDepositBalance: () => 651_000_000n, ...over.a })
    .add(B, PROVIDER, {
      getSource: () => SRC_B,
      getDepositBalance: () => {
        throw revert('0x');
      },
      ...over.b,
    });
}

const strategyOn = (chain: FakeChain) => new Contract(STRAT, STRATEGY, chain as any);

test('fee and conversion mirror reproduce the contract vectors', () => {
  // every provider answers: getAccruedFees() and convertToAssets() of the contract
  assert.deepEqual(accruedFeeShares(1_051_000_000n, GOLDEN), [9_295_838n, 1_663_494n]);
  assert.equal(sharesToAssets(SHARES, 1_051_000_000n, GOLDEN), 1_038_579_285n);
  // B's 400 USDC left out
  assert.deepEqual(accruedFeeShares(651_000_000n, GOLDEN), [0n, 1_648_187n]);
  assert.equal(sharesToAssets(SHARES, 651_000_000n, GOLDEN), 649_280_583n);
  // edges of _accruedFees
  assert.throws(() => accruedFeeShares(1n, { ...GOLDEN, highWaterMark: 0n }), /SecurityAccountingNotInitialized/);
  assert.deepEqual(accruedFeeShares(0n, GOLDEN), [0n, 0n]);
  assert.equal(sharesToAssets(5n, 0n, { ...GOLDEN, supply: 0n }), 5n);
  const noFees = { ...GOLDEN, managementFee: 0n, performanceFee: 0n };
  assert.equal(sharesToAssets(SHARES, 651_000_000n, noFees), (SHARES * 651_000_000n) / GOLDEN.supply);
});

test('a healthy strategy is valued by convertToAssets alone', async () => {
  const chain = currentStrategy({ strategy: { providersHealthy: () => true, convertToAssets: ([s]) => s * 2n } });
  const v = await strategyShareValue(strategyOn(chain), 7n, BLOCK);
  assert.deepEqual(v, { healthy: true, blocked: false, value: 14n });
  assert.deepEqual(chain.calls.map((c) => c.fn), ['providersHealthy', 'convertToAssets']);
  assert.ok(chain.calls.every((c) => c.blockTag === BLOCK), 'read at the reference block');
});

test('seven-provider valuation retains Fluid/V2 and excludes only a failed or retargeted source', async () => {
  const providers = Array.from({ length: 7 }, (_, i) => addr(0x100 + i));
  const sources = providers.map((_, i) => addr(0x200 + i));
  const balances = providers.map((_, i) => BigInt(i + 1) * 100_000_000n);
  const idle = 11_000_000n;
  for (const failed of [5, 6]) { // Fluid and V2 are the appended sixth/seventh venues.
    const chain = new FakeChain()
      .add(USDC, ERC20, { balanceOf: () => idle })
      .add(STRAT, STRATEGY, {
        providersHealthy: () => false,
        convertToAssets: () => { throw revert(PROVIDER_UNAVAILABLE); },
        asset: () => USDC,
        getProviders: () => providers,
        getPinnedProviderSource: ([p]) => sources[providers.findIndex((a) => a.toLowerCase() === p.toLowerCase())],
        getManagementFee: () => 0n,
        getPerformanceFee: () => 0n,
        getHighWaterMark: () => 10n ** 18n,
        getLastTimestamp: () => GOLDEN.lastTimestamp,
        totalSupply: () => SHARES,
      });
    for (const [i, provider] of providers.entries()) chain.add(provider, PROVIDER, {
      getSource: () => failed === 6 && i === failed ? addr(0x999) : sources[i],
      getDepositBalance: () => {
        if (failed === 5 && i === failed) throw revert('0x');
        return balances[i];
      },
    });
    const value = await strategyShareValue(strategyOn(chain), SHARES, BLOCK);
    assert.equal(value.healthy, false);
    assert.equal(value.blocked, true, 'an incomplete seven-provider NAV cannot settle');
    assert.equal(value.value, 2_811_000_000n - balances[failed]);
    assert.deepEqual(value.readable!.failing, [providers[failed]]);
    assert.ok(chain.calls.every((call) => call.blockTag === BLOCK));
  }
});

test('a failing view on the current Rebalancer gives the readable lower bound instead of a revert', async () => {
  const chain = currentStrategy();
  const v = await strategyShareValue(strategyOn(chain), SHARES, BLOCK);
  assert.equal(v.healthy, false);
  assert.equal(v.blocked, true, 'the strategy itself refuses exits');
  assert.equal(v.value, 649_280_583n, 'the contract vector');
  assert.equal(v.readable!.total, 651_000_000n);
  assert.deepEqual(v.readable!.failing, [B]);
  assert.ok(chain.calls.every((c) => c.blockTag === BLOCK), 'every read at the reference block');
  const providerCalls = chain.calls.filter((c) => c.to === A.toLowerCase() || c.to === B.toLowerCase());
  assert.ok(providerCalls.length > 0 && providerCalls.every((c) => BigInt(c.gasLimit as bigint) > PROVIDER_VIEW_CALL_GAS && BigInt(c.gasLimit as bigint) < PROVIDER_VIEW_CALL_GAS + 50_000n), 'provider views get the contract stipend');
});

test('a provider is counted only behind its pinned source, as the contract counts it', async () => {
  // B answers its balance, but for another source than the pinned one
  const retargeted = currentStrategy({ b: { getSource: () => addr(0xbad), getDepositBalance: () => 400_000_000n } });
  const r1 = await readableTotalAssets(strategyOn(retargeted), BLOCK);
  assert.equal(r1.total, 651_000_000n);
  assert.deepEqual(r1.failing, [B]);
  assert.equal(retargeted.called('getDepositBalance').filter((c) => c.to === B.toLowerCase()).length, 0, 'a retargeted balance is never read');

  // no pinned source at all
  const unpinned = currentStrategy({ strategy: { getPinnedProviderSource: ([p]) => (p.toLowerCase() === A.toLowerCase() ? SRC_A : addr(0)) }, b: { getDepositBalance: () => 400_000_000n } });
  assert.deepEqual((await readableTotalAssets(strategyOn(unpinned), BLOCK)).failing, [B]);

  // idle asset of the strategy counts
  const idle = currentStrategy();
  idle.add(USDC, ERC20, { balanceOf: () => 5n });
  assert.equal((await readableTotalAssets(strategyOn(idle), BLOCK)).total, 651_000_005n);
});

test('out of gas counts the provider as failing; an RPC failure is never priced as one', async () => {
  const outOfGas = currentStrategy({
    b: {
      getDepositBalance: () => {
        throw rpcError('out of gas');
      },
    },
  });
  assert.equal((await strategyShareValue(strategyOn(outOfGas), SHARES, BLOCK)).value, 649_280_583n);

  for (const message of ['request limit reached', 'rate limit exceeded', 'header not found']) {
    const limited = currentStrategy({
      b: {
        getDepositBalance: () => {
          throw rpcError(message);
        },
      },
    });
    await assert.rejects(strategyShareValue(strategyOn(limited), SHARES, BLOCK), (e: any) => e.info?.error?.message === message, message);
  }
  const transport = currentStrategy({
    a: {
      getSource: () => {
        throw makeError('request timeout', 'TIMEOUT', { operation: 'eth_call' } as any);
      },
    },
  });
  await assert.rejects(strategyShareValue(strategyOn(transport), SHARES, BLOCK), /timeout/);
});

test('a conversion revert other than ProviderUnavailable is not taken for a failing view', async () => {
  const chain = currentStrategy({
    strategy: {
      convertToAssets: () => {
        throw revert(id('SecurityAccountingNotInitialized()').slice(0, 10));
      },
    },
  });
  await assert.rejects(strategyShareValue(strategyOn(chain), SHARES, BLOCK));
  // an RPC that strips revert data still identifies the revert by the node's message
  const stripped = currentStrategy({
    strategy: {
      convertToAssets: () => {
        throw rpcError('execution reverted');
      },
    },
  });
  assert.equal((await strategyShareValue(strategyOn(stripped), SHARES, BLOCK)).value, 649_280_583n);
});

test('an implementation before the complete-NAV rule keeps its own under-stated conversion', async () => {
  // live Base/Arbitrum strategies: no revert, no pinning or fee getters
  const chain = currentStrategy({
    strategy: {
      convertToAssets: () => 600_000_000n,
      getPinnedProviderSource: undefined as any,
      getHighWaterMark: undefined as any,
    },
  });
  const v = await strategyShareValue(strategyOn(chain), SHARES, BLOCK);
  assert.deepEqual(v, { healthy: false, blocked: false, value: 600_000_000n });
  assert.equal(chain.called('getProviders').length, 0, 'no readable path needed');

  // the monitor still learns which provider fails: no pinning there, balance views only
  const r = await readableTotalAssets(strategyOn(chain), BLOCK);
  assert.deepEqual(r, { total: 651_000_000n, failing: [B] });
});

test('NAV values an unhealthy strategy at the readable bound, offer at least the last accepted offer', async () => {
  const chain = currentStrategy().add(AGENT, CHAIN_AGENT, { strategy: () => STRAT });
  const c: any = { key: 'mainnet', chainId: 1n, entry: { usdc: USDC }, manifest: { contracts: { ChainAgent: AGENT } }, provider: chain };
  const key = positionKey({ chainId: 1n, holder: AGENT, strategy: STRAT, kind: KIND_STRATEGY_SHARES });

  const unhealthy: string[] = [];
  const higher = await positionsAt(c, BLOCK, new Map([[key, 1_038_579_285n]]), unhealthy);
  assert.equal(higher.length, 1, 'no idle entry when the agent holds none');
  assert.equal(higher[0].valueBid, 649_280_583n, 'bid: what is readable, safe for exits');
  assert.equal(higher[0].valueOffer, 1_038_579_285n, 'offer: the previous accepted offer');
  assert.deepEqual(unhealthy, [`mainnet:${STRAT}`]);

  const lower = await positionsAt(c, BLOCK, new Map([[key, 1n]]), []);
  assert.equal(lower[0].valueOffer, 649_280_583n, 'offer never below bid');
});
