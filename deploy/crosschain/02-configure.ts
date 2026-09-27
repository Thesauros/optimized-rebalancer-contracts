/**
 * Phase 2: wire the connected network to its peers. Run after phase 1 on
 * every network (it reads the peers' manifests), and again on existing
 * networks whenever a network is added to the registry.
 *
 *   npx hardhat run deploy/crosschain/02-configure.ts --network base
 *   npx hardhat run deploy/crosschain/02-configure.ts --network arbitrum
 *
 * Runs while the deployer still holds ADMIN_ROLE and acts as timelock (before
 * phase 3). After phase 3 the same changes go through the Timelock; the script
 * then prints what it would do and exits (see --plan in the runbook).
 */
import { ethers } from 'hardhat';
import { NETWORKS, identities, routeId } from './registry';
import {
  EXECUTOR_ROLE,
  GUARDIAN_ROLE,
  NAV_UPDATER_ROLE,
  banner,
  currentEntry,
  deployer,
  ensureRole,
  peers,
  requireManifest,
  send,
  writeManifest,
} from './lib';

async function main() {
  const [key, entry] = await currentEntry();
  const ids = identities();
  const signer = await deployer();
  const me = await signer.getAddress();
  banner('Phase 2 configure');

  const m = requireManifest(key, 1);
  if (m.phase >= 3) {
    throw new Error(`${key} is handed over (phase 3). Configuration changes must be queued through the Timelock.`);
  }
  const c = m.contracts;

  const agent = await ethers.getContractAt('ChainAgent', c.ChainAgent, signer);
  const adapter = await ethers.getContractAt('CctpV2Adapter', c.CctpV2Adapter, signer);
  const strategy = await ethers.getContractAt('Rebalancer', c.Strategy, signer);

  // transport and routes to every peer that has been deployed
  if (!(await agent.isAdapter(c.CctpV2Adapter))) {
    await send('ChainAgent.setAdapter', agent.setAdapter(c.CctpV2Adapter, true));
  }
  for (const [peerKey, peer] of peers(key)) {
    const pm = requireManifest(peerKey, 1);
    const remote = await adapter.remotes(peer.chainId);
    if (!remote.set || remote.adapter.toLowerCase() !== pm.contracts.CctpV2Adapter.toLowerCase() || Number(remote.domain) !== peer.cctp.domain) {
      await send(`CctpV2Adapter.setRemote(${peerKey})`, adapter.setRemote(peer.chainId, peer.cctp.domain, pm.contracts.CctpV2Adapter));
    }
    if (!(await agent.isPeer(peer.chainId, pm.contracts.ChainAgent))) {
      await send(`ChainAgent.setPeer(${peerKey})`, agent.setPeer(peer.chainId, pm.contracts.ChainAgent, true));
    }
    const limits = entry.routes[peer.chainId.toString()];
    if (!limits) {
      console.log(`  - no route ${key} -> ${peerKey} in the registry (receive-only)`);
      continue;
    }
    const rid = routeId(entry.chainId, peer.chainId);
    const route = await agent.getRoute(rid);
    if (route.adapter === ethers.ZeroAddress) {
      await send(
        `ChainAgent.addRoute(${key}->${peerKey})`,
        agent.addRoute(rid, c.CctpV2Adapter, peer.chainId, pm.contracts.ChainAgent, limits.maxFeeBps, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond),
      );
    } else if (
      route.dstAgent.toLowerCase() !== pm.contracts.ChainAgent.toLowerCase() ||
      route.adapter.toLowerCase() !== c.CctpV2Adapter.toLowerCase()
    ) {
      throw new Error(`route ${key}->${peerKey} exists with different endpoints; endpoints are permanent, use a new route id`);
    } else if (
      route.maxPerTransfer !== limits.maxPerTransfer ||
      route.capacity !== limits.capacity ||
      route.refillPerSecond !== limits.refillPerSecond ||
      Number(route.maxFeeBps) !== limits.maxFeeBps ||
      !route.enabled
    ) {
      await send(
        `ChainAgent.configureRoute(${key}->${peerKey})`,
        agent.configureRoute(rid, true, limits.maxFeeBps, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond),
      );
    }
  }

  // strategy provider caps
  const labelled: Record<string, string> = Object.fromEntries(entry.strategy.reusedProviders.map((p) => [p.label, p.address]));
  if (c.CompoundV3Provider) labelled.CompoundV3 = c.CompoundV3Provider;
  for (const [label, bps] of Object.entries(entry.strategy.capsBps)) {
    const provider = labelled[label];
    if (!provider) throw new Error(`cap for unknown provider label ${label}`);
    if (BigInt(await strategy.getProviderCap(provider)) !== BigInt(bps)) {
      await send(`Strategy.setProviderCap(${label}, ${bps})`, strategy.setProviderCap(provider, bps));
    }
  }

  // operational roles
  await ensureRole(strategy, 'Strategy', EXECUTOR_ROLE, 'EXECUTOR', ids.executor);
  await ensureRole(agent, 'ChainAgent', EXECUTOR_ROLE, 'EXECUTOR', ids.executor);
  await ensureRole(agent, 'ChainAgent', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian);

  if (entry.role === 'hub') {
    const accountant = await ethers.getContractAt('TickAccountant', c.TickAccountant, signer);
    const vault = await ethers.getContractAt('EpochVault', c.EpochVault, signer);
    for (const [netKey, net] of Object.entries(NETWORKS)) {
      const nm = requireManifest(netKey, 1);
      if (!(await accountant.isAgent(net.chainId, nm.contracts.ChainAgent))) {
        await send(`TickAccountant.setAgent(${netKey})`, accountant.setAgent(net.chainId, nm.contracts.ChainAgent, true));
      }
    }
    const want = Object.values(NETWORKS).map((n) => n.chainId).sort((a, b) => (a < b ? -1 : 1));
    const have: bigint[] = (await accountant.chainIds()).map((x: bigint) => BigInt(x));
    if (have.join() !== want.join()) {
      await send('TickAccountant.setChains', accountant.setChains(want));
    }
    if ((await vault.hubAgent()).toLowerCase() !== c.ChainAgent.toLowerCase()) {
      await send('EpochVault.setHubAgent', vault.setHubAgent(c.ChainAgent));
    }
    await ensureRole(accountant, 'TickAccountant', NAV_UPDATER_ROLE, 'NAV_UPDATER', ids.navUpdater);
    await ensureRole(accountant, 'TickAccountant', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian);
    await ensureRole(vault, 'EpochVault', EXECUTOR_ROLE, 'EXECUTOR', ids.executor);
    await ensureRole(vault, 'EpochVault', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian);
  }

  m.phase = Math.max(m.phase, 2);
  writeManifest(m);
  console.log(`\nPhase 2 complete for ${key} (deployer ${me}).`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
