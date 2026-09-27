/**
 * Phase 3: hand every privilege from the deployer to governance.
 *
 *   npx hardhat run deploy/crosschain/03-handover.ts --network base
 *   npx hardhat run deploy/crosschain/03-handover.ts --network arbitrum
 *
 * Per AccessManager contract (strategy, agent, and on the hub the accountant
 * and vault): set the Timelock as timelock, grant ADMIN_ROLE to the Safe,
 * revoke ADMIN_ROLE from the deployer (last). The CCTP adapter's governance
 * moves to the Timelock. ProviderManager ownership is offered to the Safe
 * (Ownable2Step): the Safe must call acceptOwnership(); phase 4 fails until it has.
 *
 * ProxyAdmins and the Timelock are owned by the Safe since phase 1.
 */
import { ethers } from 'hardhat';
import { identities } from './registry';
import { ADMIN_ROLE, banner, currentEntry, deployer, requireManifest, send, writeManifest } from './lib';

async function main() {
  const [key, entry] = await currentEntry();
  const ids = identities();
  const signer = await deployer();
  const me = await signer.getAddress();
  banner('Phase 3 handover');

  const m = requireManifest(key, 2);
  const c = m.contracts;
  const timelock = c.Timelock;

  const managed: [string, string][] = [
    ['Strategy', 'Rebalancer'],
    ['ChainAgent', 'ChainAgent'],
  ];
  if (entry.role === 'hub') {
    managed.push(['TickAccountant', 'TickAccountant'], ['EpochVault', 'EpochVault']);
  }

  for (const [name, artifact] of managed) {
    const contract: any = await ethers.getContractAt(artifact, c[name], signer);
    const current = await contract.getTimelock();
    if (current.toLowerCase() !== timelock.toLowerCase()) {
      if (current.toLowerCase() !== me.toLowerCase()) throw new Error(`${name}: timelock is ${current}, neither deployer nor Timelock`);
      await send(`${name}.setTimelock(Timelock)`, contract.setTimelock(timelock));
    }
    if (!(await contract.hasRole(ADMIN_ROLE, ids.safe))) {
      await send(`${name}.grantRole(ADMIN, Safe)`, contract.grantRole(ADMIN_ROLE, ids.safe));
    }
    if (await contract.hasRole(ADMIN_ROLE, me)) {
      await send(`${name}.revokeRole(ADMIN, deployer)`, contract.revokeRole(ADMIN_ROLE, me));
    }
  }

  const adapter = await ethers.getContractAt('CctpV2Adapter', c.CctpV2Adapter, signer);
  if ((await adapter.governance()).toLowerCase() === me.toLowerCase()) {
    await send('CctpV2Adapter.transferGovernance(Timelock)', adapter.transferGovernance(timelock));
  }

  if (c.ProviderManager) {
    const pm = await ethers.getContractAt('ProviderManager', c.ProviderManager, signer);
    const owner = await pm.owner();
    const pending = await pm.pendingOwner();
    if (owner.toLowerCase() === me.toLowerCase() && pending.toLowerCase() !== ids.safe.toLowerCase()) {
      await send('ProviderManager.transferOwnership(Safe)', pm.transferOwnership(ids.safe));
    }
    if (owner.toLowerCase() !== ids.safe.toLowerCase()) {
      console.log(`  ! Safe must call ProviderManager(${c.ProviderManager}).acceptOwnership() on ${key}`);
    }
  }

  m.phase = Math.max(m.phase, 3);
  writeManifest(m);
  console.log(`\nPhase 3 complete for ${key}. Run phase 4 to verify.`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
