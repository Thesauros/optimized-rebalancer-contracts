/**
 * NAV updater: builds the snapshot across all registry chains and commits a
 * Tick on the hub.
 *
 *   NAV_UPDATER_PRIVATE_KEY   key holding NAV_UPDATER_ROLE on the TickAccountant
 *   NAV_INTERVAL_SECONDS      target cadence (default 3600)
 *   NAV_POLL_SECONDS          loop period (default 60)
 *   PORT_NAV                  status port (default 8081)
 *
 * Commits when the cadence is due, or earlier when a closed epoch waits for a
 * Tick observed after its cutoff (so clearing is never held up by the cadence).
 * A snapshot that would quarantine is still committed: suppressing a real loss
 * is the one outcome the design must avoid; the alert goes out instead.
 */
import { Contract } from 'ethers';
import { EPOCH_VAULT, TICK_ACCOUNTANT } from './abi';
import { envNumber, hubOf, loadChains, signerFor } from './config';
import { Snapshot, TransferIndex, buildSnapshot, committedSnapshot, offersOf } from './snapshot';
import { log, loop, serveStatus, telegram } from './util';

const SERVICE = 'nav';
const WAD = 10n ** 18n;

async function main() {
  const chains = loadChains();
  const hub = hubOf(chains);
  const signer = signerFor(hub, 'NAV_UPDATER_PRIVATE_KEY');
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, signer);
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  const index = new TransferIndex();
  const interval = BigInt(envNumber('NAV_INTERVAL_SECONDS', 3600));

  let lastSnapshot: Snapshot | undefined;
  let lastSuccess = 0;
  let lastError = '';
  let lastTick: Record<string, unknown> = {};

  serveStatus(SERVICE, envNumber('PORT_NAV', 8081), {
    healthy: () => lastError === '' && Date.now() - lastSuccess < envNumber('NAV_HEALTH_MAX_AGE_SECONDS', 5400) * 1000,
    status: () => ({ lastSuccess: new Date(lastSuccess).toISOString(), lastError, lastTick }),
  });

  await loop(SERVICE, envNumber('NAV_POLL_SECONDS', 60) * 1000, async () => {
    try {
      const [, latest] = await accountant.latestAccepted();
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
      const built = await buildSnapshot(chains, index, lastSnapshot ? offersOf(lastSnapshot) : new Map());
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
        await telegram(
          `🟠 Tick ${built.snapshot.tickId} QUARANTINED\nmove ${Number(moveBps) / 100}% vs last accepted rate ${Number((prevRate * 1_000_000n) / WAD) / 1e6}\n` +
            `Settlement is frozen until an in-bounds Tick or ADMIN ratifyTick. tx ${tx.hash}`,
        );
      } else {
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
