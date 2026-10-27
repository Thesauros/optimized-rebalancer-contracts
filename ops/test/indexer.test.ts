import { test } from 'node:test';
import assert from 'node:assert/strict';
import { annualized, deriveRequest, instantRemaining, providerLabel } from '../src/indexer';
import type { NetworkEntry } from '../../deploy/crosschain/registry';

const WAD = 10n ** 18n;
const epoch = (o: Partial<Parameters<typeof deriveRequest>[5]> = {}) => ({
  closedAt: 1000n,
  depositsCleared: false,
  redeemsCleared: false,
  funded: false,
  rateOffer: WAD,
  priceRedeem: WAD,
  ...o,
});

test('deposit request lifecycle: pending -> clearing -> claimable -> claimed', () => {
  assert.deepEqual(deriveRequest('deposit', 'requested', 100n, 5n, 5n, epoch()), { state: 'pending', cancellable: true, claimable: 0n });
  assert.equal(deriveRequest('deposit', 'requested', 100n, 5n, 6n, epoch()).state, 'clearing');
  const c = deriveRequest('deposit', 'requested', 1_000_000n, 5n, 6n, epoch({ depositsCleared: true, rateOffer: 2n * WAD }));
  assert.equal(c.state, 'claimable');
  assert.equal(c.claimable, 500_000n, 'shares = assets / offer rate');
  assert.equal(c.cancellable, false, 'a priced deposit can no longer be pulled out');
  assert.equal(deriveRequest('deposit', 'claimed', 100n, 5n, 6n, epoch()).state, 'claimed');
  assert.equal(deriveRequest('deposit', 'cancelled', 100n, 5n, 5n, epoch()).state, 'cancelled');
});

test('an unpriced deposit stays cancellable past the cutoff, a redeem does not', () => {
  // The refund is NAV-neutral and this is the only exit for a deposit caught in a frozen epoch.
  assert.equal(deriveRequest('deposit', 'requested', 100n, 5n, 6n, epoch()).cancellable, true);
  // A redeem's price is fixed only at clearing, so a late cancel would be a free option.
  assert.equal(deriveRequest('redeem', 'requested', 100n, 5n, 6n, epoch()).cancellable, false);
  assert.equal(deriveRequest('redeem', 'requested', 100n, 5n, 5n, epoch()).cancellable, true, 'still open in its own epoch');
});

test('redeem request waits for liquidity after clearing', () => {
  const cleared = epoch({ redeemsCleared: true, priceRedeem: (WAD * 101n) / 100n });
  const w = deriveRequest('redeem', 'requested', 1_000_000n, 5n, 6n, cleared);
  assert.equal(w.state, 'awaiting_liquidity');
  assert.equal(w.claimable, 1_010_000n);
  assert.equal(deriveRequest('redeem', 'requested', 1_000_000n, 5n, 6n, { ...cleared, funded: true }).state, 'claimable');
});

test('instant bucket replay mirrors the contract (capacity = daily limit, linear refill)', () => {
  const day = 86_400;
  assert.equal(instantRemaining(50n, [], 0), 50n);
  assert.equal(instantRemaining(50n, [{ time: 0, assets: 30n }], 0), 20n);
  assert.equal(instantRemaining(50n, [{ time: 0, assets: 30n }], day / 2), 45n, 'half a day refills 25');
  assert.equal(instantRemaining(50n, [{ time: 0, assets: 30n }, { time: 10, assets: 20n }], 10), 0n);
  assert.equal(instantRemaining(50n, [{ time: 0, assets: 50n }], 2 * day), 50n, 'capped at capacity');
});

test('annualized rate growth', () => {
  const r = annualized(WAD, (WAD * 10_001n) / 10_000n, 86_400)!;
  assert.ok(r > 0.036 && r < 0.038, `1bp/day ≈ 3.7% APR, got ${r}`);
  assert.equal(annualized(WAD, WAD, 60), null, 'too short a window');
});

test('provider labels distinguish the Morpho vaults that share one identifier', () => {
  const entry = {
    strategy: {
      reusedProviders: [
        { label: 'AaveV3', address: '0xDDAA9700c0Da1020AE5dabC7AA0A0bb750DD317c' },
        { label: 'GauntletCoreMorpho', address: '0x51B8BdCdA5E41893737C9C3A08f528C97fCc1b8b' },
        { label: 'SteakhousePrimeMorpho', address: '0xDDf2C1f8EAf567c084dEE07658Ed3906029395b1' },
      ],
    },
  } as unknown as NetworkEntry;
  const contracts = { CompoundV3Provider: '0xa408A565a34B72FD6091f24b7ad4A15dCd29038a', Strategy: '0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33' };

  assert.equal(providerLabel(entry, contracts, '0xddaa9700c0da1020ae5dabc7aa0a0bb750dd317c'), 'AaveV3', 'matched case-insensitively');
  assert.equal(providerLabel(entry, contracts, '0x51B8BdCdA5E41893737C9C3A08f528C97fCc1b8b'), 'GauntletCoreMorpho');
  assert.equal(providerLabel(entry, contracts, '0xDDf2C1f8EAf567c084dEE07658Ed3906029395b1'), 'SteakhousePrimeMorpho');
  assert.equal(providerLabel(entry, contracts, '0xa408A565a34B72FD6091f24b7ad4A15dCd29038a'), 'CompoundV3', 'freshly deployed provider, named by its manifest entry');
  assert.equal(providerLabel(entry, contracts, '0x4cBb4042F79e150F99D3Da4d666e10fdB0711F33'), 'Strategy');
  assert.equal(providerLabel(entry, contracts, '0x0000000000000000000000000000000000000001'), null, 'unknown address stays unnamed');
});
test('indexer checkpoints only chunks whose hub and agent streams both succeeded', async () => {
  const { Indexer } = await import('../src/indexer');
  const indexer: any = Object.create(Indexer.prototype);
  const chain = { key: 'test', entry: { confirmations: 0 }, manifest: { startBlock: 1 }, provider: { getBlockNumber: async () => 25_000 } };
  indexer.chains = [chain];
  indexer.hub = chain;
  let cursor = 0;
  indexer.meta = () => cursor;
  indexer.setMeta = (_key: string, block: number) => { cursor = block; };
  const starts: number[] = [];
  indexer.syncHub = async (from: number) => { starts.push(from); };
  indexer.syncAgent = async (_chain: unknown, from: number) => {
    if (from > 10_000) throw new Error('upstream failure');
  };
  await assert.rejects(indexer.sync());
  assert.equal(cursor, 10_000);
  indexer.syncAgent = async () => {};
  await indexer.sync();
  assert.deepEqual(starts, [1, 10_001, 10_001, 20_001]);
  assert.equal(cursor, 25_000);
});
