/** Offline image/startup smoke check: validates manifests and RPC configuration; sends nothing. */
import { loadChains } from './config';

try {
  const chains = loadChains();
  try {
    console.log(JSON.stringify({ networks: chains.map((c) => ({ network: c.key, chainId: c.chainId.toString(), role: c.entry.role, profile: c.manifest.profile })) }));
  } finally {
    for (const chain of chains) {
      chain.provider.destroy();
      if ('sender' in chain.provider) (chain.provider.sender as { destroy(): void }).destroy();
    }
  }
} catch (e) {
  console.error(`FAIL configuration: ${(e as Error).message}`);
  process.exitCode = 1;
}
