/**
 * Phase 4: read-only verification of a handed-over network. Exits non-zero on
 * any failed check. The same checks run continuously in the monitor.
 *
 *   npx hardhat run deploy/crosschain/04-verify.ts --network base
 *   npx hardhat run deploy/crosschain/04-verify.ts --network arbitrum
 */
import { ethers } from 'hardhat';
import { NETWORKS, identities } from './registry';
import { banner, currentEntry, readManifest, requireManifest } from './lib';
import { checkDeployment } from '../../ops/src/checks/deployment';

async function main() {
  const [key] = await currentEntry();
  const ids = identities();
  banner('Phase 4 verify');
  const m = requireManifest(key, 1);
  const manifests: Record<string, any> = {};
  for (const k of Object.keys(NETWORKS)) {
    const pm = readManifest(k);
    if (pm) manifests[k] = pm;
  }
  const results = await checkDeployment(ethers.provider as any, key, m, manifests, ids);
  let failed = 0;
  for (const r of results) {
    if (!r.ok) failed++;
    console.log(`  ${r.ok ? '✓' : '✗'} ${r.label}${r.detail ? `  (${r.detail})` : ''}`);
  }
  console.log(`\n${results.length - failed}/${results.length} checks passed on ${key}`);
  if (failed) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
