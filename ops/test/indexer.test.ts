import { test } from 'node:test';
import assert from 'node:assert/strict';
import { annualized, deriveRequest, instantRemaining } from '../src/indexer';

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
  assert.equal(deriveRequest('deposit', 'claimed', 100n, 5n, 6n, epoch()).state, 'claimed');
  assert.equal(deriveRequest('deposit', 'cancelled', 100n, 5n, 5n, epoch()).state, 'cancelled');
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
