/**
 * NAV updater: builds the snapshot across all registry chains and commits a
 * Tick on the hub.
 *
 *   NAV_UPDATER_PRIVATE_KEY   key holding NAV_UPDATER_ROLE on the TickAccountant
 *   NAV_INTERVAL_SECONDS      target cadence (default 3600)
 *   NAV_POLL_SECONDS          loop period (default 60)
 *   NAV_SNAPSHOT_SEND_MARGIN_SECONDS
 *                             refresh snapshots this close to expiry (default 15)
 *   PORT_NAV                  status port (default 8081)
 *
 * Commits when the cadence is due, or earlier when a closed epoch waits for a
 * Tick observed after its cutoff (so clearing is never held up by the cadence).
 * A snapshot that would quarantine is still committed: suppressing a real loss is
 * the one outcome the design must avoid, and the alert goes out once per episode.
 * The single exception is a Tick submitted while a quarantine already stands and
 * the move still exceeds the refilled bucket — the contract would reject it, so
 * it settles nothing, and re-submitting it every cadence for days only burns gas
 * and repeats the alert. `--force` overrides that.
 */
import { Contract } from 'ethers';
import { EPOCH_VAULT, TICK_ACCOUNTANT } from './abi';
import { envNumber, hubOf, loadChains, signerFor } from './config';
import { snapshotRefreshReason } from './nav-freshness';
import { Built, Snapshot, buildSnapshot, committedSnapshot, offersOf, openTransferIndex } from './snapshot';
import { log, loop, serveStatus, telegram } from './util';

const SERVICE = 'nav';
const WAD = 10n ** 18n;

async function main() {
  const chains = loadChains();
  const hub = hubOf(chains);
  const signer = signerFor(hub, 'NAV_UPDATER_PRIVATE_KEY');
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, signer);
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  const index = await openTransferIndex(chains);
  const interval = BigInt(envNumber('NAV_INTERVAL_SECONDS', 3600));

  let lastSnapshot: Snapshot | undefined;
  let lastSuccess = 0;
  let lastError = '';
  let lastTick: Record<string, unknown> = {};
  // one alert per quarantine episode: the monitor owns the repeat cadence, and a
  // five-minute alert loop for days trains operators to ignore the channel
  let quarantineAlerted = false;

  serveStatus(SERVICE, envNumber('PORT_NAV', 8081), {
    healthy: () => lastError === '' && Date.now() - lastSuccess < envNumber('NAV_HEALTH_MAX_AGE_SECONDS', 5400) * 1000,
    status: () => ({ lastSuccess: new Date(lastSuccess).toISOString(), lastError, lastTick }),
  });

  await loop(SERVICE, envNumber('NAV_POLL_SECONDS', 60) * 1000, async () => {
    try {
      let [, latest] = await accountant.latestAccepted();
      const lastId: bigint = await accountant.lastTickId();
      const last = await accountant.getTick(lastId);
      const cfg = await accountant.config();
      const now = BigInt((await hub.provider.getBlock('latest'))!.timestamp);

      // cadence, or a closed epoch whose cutoff is after the latest accepted observation
      const current: bigint = await vault.currentEpoch();
      const [nextDeposit, nextRedeem] = await vault.cursors();
      const oldestOpen = nextDeposit < nextRedeem ? nextDeposit : nextRedeem;
      let clearingWaits = false;
      if (oldestOpen < current) {
        const e = await vault.getEpoch(oldestOpen);
        clearingWaits = BigInt(latest.referenceTime) < BigInt(e.closedAt);
      }
      const due = now - BigInt(last.committedAt) >= interval || clearingWaits || process.argv.includes('--force');
      if (!due || now < BigInt(last.committedAt) + BigInt(cfg.minTickInterval)) {
        log(SERVICE, 'no tick due', { due, clearingWaits, secondsSinceLast: now - BigInt(last.committedAt), minTickInterval: cfg.minTickInterval });
        lastSuccess = Date.now();
        lastError = '';
        return;
      }

      if (!lastSnapshot) {
        // restore the previous accepted snapshot for the unhealthy-offer rule
        const acceptedId: bigint = await accountant.lastAcceptedTickId();
        lastSnapshot = (await committedSnapshot(hub, acceptedId))?.snapshot;
      }
      let built: Built;
      for (let buildAttempt = 0; ; buildAttempt += 1) {
        built = await buildSnapshot(chains, index, lastSnapshot ? offersOf(lastSnapshot) : new Map());
        const currentLastId: bigint = await accountant.lastTickId();
        const currentLast = await accountant.getTick(currentLastId);
        const currentCfg = await accountant.config();
        const currentNow = BigInt((await hub.provider.getBlock('latest'))!.timestamp);
        const reason = snapshotRefreshReason(built.snapshot, {
          lastTickId: currentLastId,
          lastReferenceTime: BigInt(currentLast.referenceTime),
          now: currentNow,
          maxSnapshotAge: BigInt(currentCfg.maxSnapshotAge),
          sendMargin: BigInt(envNumber('NAV_SNAPSHOT_SEND_MARGIN_SECONDS', 15)),
        });
        if (!reason) break;
        if (buildAttempt > 0) throw new Error(`snapshot remained stale after refresh: ${reason}`);
        log(SERVICE, 'snapshot became stale while building; rebuilding', {
          reason,
          tickId: built.snapshot.tickId,
          referenceTime: built.snapshot.referenceTime,
        });
        [, latest] = await accountant.latestAccepted();
      }
      const prevRate = BigInt(latest.rateBid);
      const moveBps = prevRate === 0n ? 0n : ((built.totals.grossBid - prevRate) * 10_000n) / prevRate;
      log(SERVICE, 'snapshot built', {
        tickId: built.snapshot.tickId,
        refs: Object.fromEntries(built.refs),
        navBid: built.totals.navBid,
        navOffer: built.totals.navOffer,
        grossBid: built.totals.grossBid,
        moveBps,
        positions: built.snapshot.positions.length,
        inFlight: built.snapshot.inFlight.length,
        unhealthy: built.unhealthy,
      });

      // While a quarantine stands, a Tick that would quarantine again settles
      // nothing, costs gas and re-fires the alert every cadence until the bucket
      // refills — days for a large loss. Skip only the commits the contract is
      // certain to reject: if the move now fits the refilled bucket, committing is
      // what resolves the quarantine, so it always goes through. A real loss is
      // never suppressed, only not re-submitted at a rate it cannot pass.
      //
      // The trade-off is a gap in the on-chain append-only trail for the skipped
      // observations. The service log and /health carry them instead, and a long
      // quarantine is already an ADMIN incident, so the trail that matters is the
      // one that ends in `ratifyTick`.
      if (await accountant.quarantined()) {
        const [up, down] = await accountant.buckets();
        const rising = built.totals.grossBid >= prevRate;
        const b = rising ? up : down;
        const elapsed = now > BigInt(b.updatedAt) ? now - BigInt(b.updatedAt) : 0n;
        const refilled = BigInt(b.level) + BigInt(b.refillPerSecond) * elapsed;
        const room = refilled > BigInt(b.capacity) ? BigInt(b.capacity) : refilled;
        const delta = rising ? built.totals.grossBid - prevRate : prevRate - built.totals.grossBid;
        // ceil, matching `_consumeBuckets`
        const needed = prevRate === 0n ? 0n : (delta * WAD + prevRate - 1n) / prevRate;
        if (needed > room && !process.argv.includes('--force')) {
          log(SERVICE, 'quarantined and the move still exceeds the bucket; not committing', {
            needed: needed.toString(),
            room: room.toString(),
            moveBps,
          });
          lastSuccess = Date.now();
          lastError = '';
          return;
        }
      }

      await accountant.commitTick.staticCall(built.snapshot, built.hubCheckpointIndex);
      const tx = await accountant.commitTick(built.snapshot, built.hubCheckpointIndex);
      const receipt = await tx.wait();
      const ev = receipt!.logs
        .map((l: any) => { try { return accountant.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === 'TickCommitted');
      const status = Number(ev?.args.status);
      lastTick = {
        tickId: built.snapshot.tickId.toString(),
        status: ['None', 'Accepted', 'Quarantined', 'Ratified'][status],
        rateBid: ev?.args.rateBid?.toString(),
        navBid: built.totals.navBid.toString(),
        tx: tx.hash,
      };
      log(SERVICE, 'tick committed', lastTick);
      if (status === 2) {
        if (!quarantineAlerted) {
          await telegram(
            `🟠 Tick ${built.snapshot.tickId} QUARANTINED\nmove ${Number(moveBps) / 100}% vs last accepted rate ${Number((prevRate * 1_000_000n) / WAD) / 1e6}\n` +
              `Settlement is frozen until an in-bounds Tick or ADMIN ratifyTick. tx ${tx.hash}`,
          );
          quarantineAlerted = true;
        }
      } else {
        quarantineAlerted = false;
        lastSnapshot = built.snapshot;
      }
      lastSuccess = Date.now();
      lastError = '';
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  });
}

main().catch((e) => {
  log(SERVICE, 'fatal', { error: String(e) });
  process.exit(1);
});
