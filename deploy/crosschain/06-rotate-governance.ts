/**
 * Phase 6: move a stand deployment from the single EOA to production identities.
 *
 *   CROSSCHAIN_PROFILE=stand \
 *   CROSSCHAIN_SAFE=<current EOA> CROSSCHAIN_NAV_UPDATER=... (current values) \
 *   NEW_SAFE=0x... NEW_NAV_UPDATER=0x... NEW_EXECUTOR=0x... NEW_GUARDIAN=0x... \
 *   npx hardhat run deploy/crosschain/06-rotate-governance.ts --network base
 *
 * Signed by the current governance EOA (the stand's deployer key). Every step is
 * a direct ADMIN / owner action; no Timelock delay is involved:
 *   1. grant the new operational roles, revoke the old holders;
 *   2. grant ADMIN_ROLE to the new Safe;
 *   3. ProxyAdmin.transferOwnership(new Safe) for every proxy (single step, OZ 5);
 *   4. Timelock.transferOwnership(new Safe) and ProviderManager.transferOwnership
 *      (Ownable2Step: the new Safe must acceptOwnership on both);
 *   5. revoke the EOA's ADMIN_ROLE last.
 * The fee treasury (TickAccountant) moves through the Timelock: the script prints
 * the queue call. Afterwards: switch limits with a production-profile phase 5
 * plan, set the manifest profile, and run phase 4 with the new identities.
 */
import { ethers } from 'hardhat';
import { ADMIN_ROLE, EXECUTOR_ROLE, GUARDIAN_ROLE, NAV_UPDATER_ROLE, banner, currentEntry, deployer, proxyAdminOf, requireManifest, send, writeManifest } from './lib';
import { identities } from './registry';

function need(key: string): string {
  const v = process.env[key];
  if (!v || !ethers.isAddress(v)) throw new Error(`${key} must be set to an address`);
  return v;
}

async function main() {
  const [key, entry] = await currentEntry();
  banner('Phase 6 rotate governance');
  const m = requireManifest(key, 3);
  const c = m.contracts;
  const signer = await deployer();
  const me = await signer.getAddress();
  const old = identities();
  const next = { safe: need('NEW_SAFE'), navUpdater: need('NEW_NAV_UPDATER'), executor: need('NEW_EXECUTOR'), guardian: need('NEW_GUARDIAN') };

  if ((await ethers.provider.getCode(next.safe)) === '0x') throw new Error(`NEW_SAFE ${next.safe} has no code on ${key}`);
  const distinct = new Set([next.safe, next.navUpdater, next.executor, next.guardian, me].map((a) => a.toLowerCase()));
  if (distinct.size !== 5) throw new Error('new identities must be distinct from each other and from the current EOA');

  const managed: [string, string, [string, string, string, string][]][] = [
    ['Strategy', 'Rebalancer', [[EXECUTOR_ROLE, 'EXECUTOR', old.executor, next.executor]]],
    ['ChainAgent', 'ChainAgent', [[EXECUTOR_ROLE, 'EXECUTOR', old.executor, next.executor], [GUARDIAN_ROLE, 'GUARDIAN', old.guardian, next.guardian]]],
  ];
  if (entry.role === 'hub') {
    managed.push(
      ['TickAccountant', 'TickAccountant', [[NAV_UPDATER_ROLE, 'NAV_UPDATER', old.navUpdater, next.navUpdater], [GUARDIAN_ROLE, 'GUARDIAN', old.guardian, next.guardian]]],
      ['EpochVault', 'EpochVault', [[EXECUTOR_ROLE, 'EXECUTOR', old.executor, next.executor], [GUARDIAN_ROLE, 'GUARDIAN', old.guardian, next.guardian]]],
    );
  }

  for (const [name, artifact, roles] of managed) {
    const ct: any = await ethers.getContractAt(artifact, c[name], signer);
    if (!(await ct.hasRole(ADMIN_ROLE, me))) throw new Error(`${name}: signer ${me} is not ADMIN`);
    for (const [role, label, from, to] of roles) {
      if (!(await ct.hasRole(role, to))) await send(`${name}.grantRole(${label}, ${to})`, ct.grantRole(role, to));
      if (from && from.toLowerCase() !== to.toLowerCase() && (await ct.hasRole(role, from))) await send(`${name}.revokeRole(${label}, ${from})`, ct.revokeRole(role, from));
    }
    if (!(await ct.hasRole(ADMIN_ROLE, next.safe))) await send(`${name}.grantRole(ADMIN, new Safe)`, ct.grantRole(ADMIN_ROLE, next.safe));
  }

  const proxies = ['Strategy', 'ChainAgent', ...(entry.role === 'hub' ? ['TickAccountant', 'EpochVault'] : [])];
  for (const name of proxies) {
    const admin = await ethers.getContractAt('@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin', await proxyAdminOf(c[name]), signer);
    if ((await admin.owner()).toLowerCase() === me.toLowerCase()) await send(`${name} ProxyAdmin.transferOwnership(new Safe)`, admin.transferOwnership(next.safe));
  }

  const timelock = await ethers.getContractAt('Timelock', c.Timelock, signer);
  if ((await timelock.owner()).toLowerCase() === me.toLowerCase() && (await timelock.pendingOwner()).toLowerCase() !== next.safe.toLowerCase()) {
    await send('Timelock.transferOwnership(new Safe)', timelock.transferOwnership(next.safe));
  }
  if (c.ProviderManager) {
    const pm = await ethers.getContractAt('ProviderManager', c.ProviderManager, signer);
    if ((await pm.owner()).toLowerCase() === me.toLowerCase() && (await pm.pendingOwner()).toLowerCase() !== next.safe.toLowerCase()) {
      await send('ProviderManager.transferOwnership(new Safe)', pm.transferOwnership(next.safe));
    }
  }

  for (const [name, artifact] of managed) {
    const ct: any = await ethers.getContractAt(artifact, c[name], signer);
    if (await ct.hasRole(ADMIN_ROLE, me)) await send(`${name}.revokeRole(ADMIN, old EOA)`, ct.revokeRole(ADMIN_ROLE, me));
  }

  if (entry.role === 'hub') {
    const data = ethers.AbiCoder.defaultAbiCoder().encode(['address'], [next.safe]);
    console.log(`\n  Treasury (fee recipient) moves through the Timelock. Before accepting Timelock ownership, from the current owner:`);
    console.log(`  Timelock(${c.Timelock}).queue(${c.TickAccountant}, 0, "setTreasury(address)", ${data}, <now + delay>)`);
  }
  m.profile = 'production';
  writeManifest(m);
  console.log(`\nRotation sent on ${key}. The new Safe must now call acceptOwnership() on Timelock ${c.Timelock}${c.ProviderManager ? ` and ProviderManager ${c.ProviderManager}` : ''}.`);
  console.log('Then: CROSSCHAIN_PROFILE=production 05-governance-plan (limits), and 04-verify with the new identities.');
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
