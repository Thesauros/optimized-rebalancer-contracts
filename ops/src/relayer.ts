/**
 * CCTP relayer: delivers every outbound transfer to its destination agent.
 * Delivery is permissionless on-chain (ChainAgent.receiveBridge); this service
 * only provides liveness. Any other party can deliver the same message.
 *
 *   RELAYER_PRIVATE_KEY       funded key on every chain (gas only)
 *   RELAYER_ATTESTATION       "iris" (default) or "local" (fork rehearsal only)
 *   LOCAL_ATTESTER_KEY        with "local": key enabled as attester on the forks
 *   RELAYER_POLL_SECONDS      loop period (default 30)
 *   PORT_RELAYER              status port (default 8083)
 */
import { AbiCoder, Contract } from 'ethers';
import { CHAIN_AGENT } from './abi';
import { Attested, attestLocally, fetchIris } from './cctp';
import { Chain, envNumber, loadChains, signerFor } from './config';
import { openTransferIndex } from './snapshot';
import { log, loop, sendWithGasMargin, serveStatus, telegram } from './util';
import { loadNativeSpokes } from './native';
import { SOLANA } from '../../deploy/crosschain/native-registry';
import type { SolanaSpoke } from './solana/spoke';

const SERVICE = 'relayer';

async function main() {
  const chains = loadChains();
  const natives = loadNativeSpokes();
  const byChainId = new Map(chains.map((c) => [c.chainId, c]));
  const byKey = new Map(chains.map((c) => [c.key, c]));
  const mode = process.env.RELAYER_ATTESTATION ?? 'iris';
  const index = await openTransferIndex(chains);
  const delivered = new Map<string, string>();
  const pending = new Map<string, { since: number; lastError?: string }>();
  let lastError = '';
  let lastPass = 0;
  const alerted = new Set<string>();
  async function alertPending(id: string, from: string, to: string, entry: { since: number; lastError?: string }) {
    const ageMin = (Date.now() - entry.since) / 60_000;
    if (ageMin > envNumber('RELAYER_ALERT_MINUTES', 60) && !alerted.has(id)) {
      alerted.add(id);
      await telegram(
        `🟠 CCTP transfer ${id} ${from}→${to} undelivered for ${ageMin.toFixed(0)} min: ${entry.lastError ?? ''}`,
      );
    }
  }

  serveStatus(SERVICE, envNumber('PORT_RELAYER', 8083), {
    healthy: () => lastError === '' && Date.now() - lastPass < 5 * 60_000,
    status: () => ({
      mode,
      lastPass: new Date(lastPass).toISOString(),
      lastError,
      pending: Object.fromEntries(pending),
      delivered: delivered.size,
    }),
  });

  async function attestation(src: Chain, txHash: string, id: string): Promise<Attested | undefined> {
    if (mode === 'local') {
      const key = process.env.LOCAL_ATTESTER_KEY;
      if (!key) throw new Error('LOCAL_ATTESTER_KEY is not set');
      return attestLocally(src.provider, src.entry.cctp.messageTransmitter, txHash, id, key);
    }
    return fetchIris(src.entry.cctp.domain, txHash, id);
  }

  await loop(SERVICE, envNumber('RELAYER_POLL_SECONDS', 30) * 1000, async () => {
    try {
      await index.sync(chains);
      for (const [id, sent] of index.sent) {
        if (index.received.has(id) || delivered.has(id)) {
          pending.delete(id);
          continue;
        }
        const nativeSrc = natives.find((c) => c.key === sent.chainKey);
        const nativeDst = natives.find((c) => c.chainId === sent.dstChainId);
        const src = byKey.get(sent.chainKey);
        const dst = byChainId.get(sent.dstChainId);
        if (nativeDst) {
          const entry = pending.get(id) ?? { since: Date.now() };
          pending.set(id, entry);
          try {
            if (!src || mode !== 'iris')
              throw new Error('native relaying requires a registered EVM source and Circle Iris');
            const att = await attestation(src, sent.txHash, id);
            if (!att) entry.lastError = 'attestation not ready';
            else {
              const { receiveOnSolana } = await import('./solana/operations');
              const signature = await receiveOnSolana(nativeDst as SolanaSpoke, att.message, att.attestation, true);
              delivered.set(id, signature);
              pending.delete(id);
              log(SERVICE, 'delivered', { id, from: src.key, to: nativeDst.key, tx: signature });
            }
          } catch (e) {
            entry.lastError = e instanceof Error ? e.message : String(e);
          }
          if (pending.has(id)) await alertPending(id, src?.key ?? sent.chainKey, nativeDst.key, entry);
          continue;
        }
        if (!dst) {
          pending.set(id, {
            since: pending.get(id)?.since ?? Date.now(),
            lastError: `unknown destination ${sent.dstChainId}`,
          });
          continue;
        }
        const dstAgent = new Contract(
          dst.manifest.contracts.ChainAgent,
          CHAIN_AGENT,
          signerFor(dst, 'RELAYER_PRIVATE_KEY'),
        );
        if (Number((await dstAgent.getReceived(id)).receivedAt) !== 0) {
          delivered.set(id, 'by someone else');
          pending.delete(id);
          continue;
        }
        const entry = pending.get(id) ?? { since: Date.now() };
        pending.set(id, entry);
        try {
          const att = nativeSrc
            ? mode === 'iris'
              ? await fetchIris(SOLANA.cctp.domain, sent.txHash, id)
              : (() => {
                  throw new Error('native relaying requires Circle Iris');
                })()
            : await attestation(src!, sent.txHash, id);
          if (!att) {
            entry.lastError = 'attestation not ready';
          } else {
            const payload = AbiCoder.defaultAbiCoder().encode(['bytes', 'bytes'], [att.message, att.attestation]);
            const adapter = nativeSrc
              ? (nativeSrc as SolanaSpoke).manifest.hubAdapter
              : dst.manifest.contracts.CctpV2Adapter;
            await dstAgent.receiveBridge.staticCall(adapter, payload);
            const tx = await sendWithGasMargin(dstAgent, 'receiveBridge', [adapter, payload]);
            await tx.wait();
            delivered.set(id, tx.hash);
            pending.delete(id);
            log(SERVICE, 'delivered', { id, from: src?.key ?? nativeSrc!.key, to: dst.key, tx: tx.hash });
            continue;
          }
        } catch (e) {
          entry.lastError = e instanceof Error ? e.message : String(e);
        }
        await alertPending(id, src?.key ?? nativeSrc?.key ?? sent.chainKey, dst.key, entry);
      }
      lastPass = Date.now();
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
