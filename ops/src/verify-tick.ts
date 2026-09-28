/**
 * Independent verification of committed Ticks, for partners and auditors.
 *
 *   ts-node ops/src/verify-tick.ts            # latest accepted tick
 *   ts-node ops/src/verify-tick.ts 12 13 14   # specific ticks
 *
 * Needs only RPC_<NETWORK> and the public manifests. Exits non-zero if any tick
 * does not reproduce.
 */
import { Contract } from 'ethers';
import { TICK_ACCOUNTANT } from './abi';
import { hubOf, loadChains } from './config';
import { openTransferIndex, verifyTick } from './snapshot';

async function main() {
  const chains = loadChains();
  const hub = hubOf(chains);
  const accountant = new Contract(hub.manifest.contracts.TickAccountant, TICK_ACCOUNTANT, hub.provider);
  const ids = process.argv.slice(2).filter((a) => /^\d+$/.test(a)).map(BigInt);
  if (ids.length === 0) ids.push(BigInt(await accountant.lastAcceptedTickId()));
  const index = await openTransferIndex(chains);
  let failed = 0;
  for (const id of ids) {
    const r = await verifyTick(chains, index, id);
    console.log(`tick ${id}: ${r.ok ? 'REPRODUCED' : 'MISMATCH'}`);
    for (const m of r.mismatches) console.log(`  - ${m}`);
    if (!r.ok) failed++;
  }
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
