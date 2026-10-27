import { test } from 'node:test';
import assert from 'node:assert/strict';
import { snapshotRefreshReason } from '../src/nav-freshness';

const snapshot = { tickId: 18n, referenceTime: 1_000n };
const clock = {
  lastTickId: 17n,
  lastReferenceTime: 900n,
  now: 1_400n,
  maxSnapshotAge: 480n,
  sendMargin: 15n,
};

test('snapshotRefreshReason keeps a snapshot with enough time to send', () => {
  assert.equal(snapshotRefreshReason(snapshot, clock), undefined);
});

test('snapshotRefreshReason refreshes before maxSnapshotAge is exhausted', () => {
  assert.match(snapshotRefreshReason(snapshot, { ...clock, now: 1_466n })!, /age 466s/);
});

test('snapshotRefreshReason catches an obsolete tick id or reference time', () => {
  assert.match(snapshotRefreshReason(snapshot, { ...clock, lastTickId: 18n })!, /tick id/);
  assert.match(snapshotRefreshReason(snapshot, { ...clock, lastReferenceTime: 1_000n })!, /reference time/);
});
