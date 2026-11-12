import { executeInstruction } from './instructions';
import { SolanaSpoke } from './spoke';
import { nativeWriteGate, sendNative, solanaSigner } from './transactions';
import { envNumber } from '../config';
import { hubOf, loadChains } from '../config';
import { Contract } from 'ethers';
import { EPOCH_VAULT, TICK_ACCOUNTANT } from '../abi';
import { checkpointPda, decodeCheckpoint } from './codec';
import { log, loop, serveStatus } from '../util';

async function main() {
  const spoke = SolanaSpoke.fromEnvironment();
  const payer = solanaSigner('SOLANA_CHECKPOINT_KEYPAIR');
  const hub = hubOf(loadChains());
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const vault = new Contract(hub.manifest.contracts.EpochVault, EPOCH_VAULT, hub.provider);
  let lastSuccess = 0,
    lastError = '',
    lastObservedAt = 0;
  serveStatus('solana-observer', envNumber('PORT_SOLANA_OBSERVER', 8086), {
    healthy: () => !lastError && Date.now() - lastSuccess < spoke.manifest.maxCheckpointAgeSeconds * 1000,
    status: () => ({
      network: spoke.manifest.network,
      agent: spoke.agent.toBase58(),
      lastSuccess,
      lastObservedAt,
      lastError,
    }),
  });
  await loop('solana-observer', envNumber('SOLANA_OBSERVE_SECONDS', 60) * 1000, async () => {
    try {
      // Observations incur permanent account rent. Produce them when the hub
      // needs a NAV Tick, rather than paying for unused minute-by-minute state.
      const [, latest] = await accountant.latestAccepted();
      const now = (await hub.provider.getBlock('latest'))!.timestamp;
      const cadence = envNumber('NAV_INTERVAL_SECONDS', 3600);
      let needed = now - Number(latest.committedAt) >= Math.max(0, cadence - 90);
      const current = await vault.currentEpoch(),
        [nextDeposit, nextRedeem] = await vault.cursors();
      const oldest = nextDeposit < nextRedeem ? nextDeposit : nextRedeem;
      if (oldest < current) {
        const epoch = await vault.getEpoch(oldest);
        needed ||= BigInt(latest.referenceTime) < BigInt(epoch.closedAt);
      }
      if (!needed) {
        lastSuccess = Date.now();
        lastError = '';
        return;
      }
      await nativeWriteGate(async () => {
        const state = await spoke.state();
        if (state.sequence > 0n) {
          const info = await spoke.connection.getAccountInfo(
            checkpointPda(spoke.program, spoke.agent, state.sequence - 1n),
            'finalized',
          );
          if (!info || !info.owner.equals(spoke.program)) throw new Error('latest checkpoint unavailable/wrong owner');
          const prior = decodeCheckpoint(info.data);
          if (
            now - prior.timestamp <
            envNumber(
              'SOLANA_MIN_OBSERVE_INTERVAL_SECONDS',
              Math.min(180, Math.floor(spoke.manifest.maxCheckpointAgeSeconds / 2)),
            )
          ) {
            lastSuccess = Date.now();
            lastError = '';
            return;
          }
        }
        const ix = executeInstruction(
          spoke.program,
          spoke.agent,
          spoke.idle,
          payer.publicKey,
          state.sequence,
          state.strategies,
          Buffer.from([0]),
        );
        const signature = await sendNative(spoke, [ix], payer, [], `observe-${state.sequence}`, true);
        lastSuccess = Date.now();
        lastObservedAt = lastSuccess;
        lastError = '';
        log('solana-observer', 'checkpoint finalized', { signature, sequence: state.sequence });
      });
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      throw e;
    }
  });
}
main().catch((e) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exitCode = 1;
});
