import { Snapshot } from './snapshot';

export interface SnapshotClock {
  lastTickId: bigint;
  lastReferenceTime: bigint;
  now: bigint;
  maxSnapshotAge: bigint;
  sendMargin: bigint;
}

/** Returns why a built snapshot must be refreshed before commit, if any. */
export function snapshotRefreshReason(snapshot: Pick<Snapshot, 'tickId' | 'referenceTime'>, clock: SnapshotClock): string | undefined {
  if (snapshot.tickId !== clock.lastTickId + 1n) {
    return `tick id ${snapshot.tickId} no longer follows ${clock.lastTickId}`;
  }
  if (snapshot.referenceTime <= clock.lastReferenceTime) {
    return `reference time ${snapshot.referenceTime} is not after ${clock.lastReferenceTime}`;
  }
  if (snapshot.referenceTime > clock.now) {
    return `reference time ${snapshot.referenceTime} is ahead of ${clock.now}`;
  }
  const age = clock.now - snapshot.referenceTime;
  if (age + clock.sendMargin > clock.maxSnapshotAge) {
    return `age ${age}s leaves less than ${clock.sendMargin}s before the ${clock.maxSnapshotAge}s limit`;
  }
  return undefined;
}
