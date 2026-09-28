/**
 * Deployment integrity checks, shared by `deploy/crosschain/04-verify.ts` and
 * the monitor. Read-only. Each check states what the registry and manifests
 * say must be true on-chain.
 */
import { Contract, Provider, getAddress, id, keccak256 } from 'ethers';
import { ACCESS, ADAPTER, ADMIN_ROLE, CHAIN_AGENT, EPOCH_VAULT, OWNABLE, STRATEGY, TICK_ACCOUNTANT, TIMELOCK } from '../abi';
import { NETWORKS, NetworkEntry, routeId } from '../../../deploy/crosschain/registry';

const EXECUTOR_ROLE = id('EXECUTOR_ROLE');
const GUARDIAN_ROLE = id('GUARDIAN_ROLE');
const NAV_UPDATER_ROLE = id('NAV_UPDATER_ROLE');
const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

export interface CheckResult {
  ok: boolean;
  label: string;
  detail: string;
}

export interface ManifestLike {
  network: string;
  profile?: string;
  deployer: string;
  phase: number;
  contracts: Record<string, string>;
  codehashes: Record<string, string>;
}

export interface Identities {
  safe: string;
  navUpdater: string;
  executor: string;
  guardian: string;
}

const eq = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

async function slotAddress(provider: Provider, at: string, slot: string): Promise<string> {
  const raw = await provider.getStorage(at, slot);
  return getAddress('0x' + raw.slice(26));
}

export async function checkDeployment(
  provider: Provider,
  key: string,
  m: ManifestLike,
  manifests: Record<string, ManifestLike>,
  ids: Identities,
): Promise<CheckResult[]> {
  const entry: NetworkEntry = NETWORKS[key];
  const c = m.contracts;
  const out: CheckResult[] = [];
  const check = (ok: boolean, label: string, detail = '') => out.push({ ok, label, detail });

  check(m.phase >= 3, 'manifest phase', `phase ${m.phase} (3 = handed over)`);
  const stand = m.profile === 'stand';
  // in the stand profile governance may deliberately be the deployer EOA itself
  const deployerIsGovernance = stand && eq(ids.safe, m.deployer);
  if (stand) check(true, 'profile', 'STAND: single-EOA governance allowed; rotate before real TVL (06-rotate-governance.ts)');
  else {
    const code = await provider.getCode(ids.safe);
    check(code !== '0x', 'governance is a contract', code === '0x' ? `${ids.safe} has no code` : ids.safe);
  }

  // proxies: ProxyAdmin owned by the Safe, implementation unchanged since deployment
  const proxies: [string, string][] = [
    ['Strategy', 'StrategyImplementation'],
    ['ChainAgent', 'ChainAgentImplementation'],
  ];
  if (entry.role === 'hub') proxies.push(['TickAccountant', 'TickAccountantImplementation'], ['EpochVault', 'EpochVaultImplementation']);
  for (const [proxy, impl] of proxies) {
    const admin = await slotAddress(provider, c[proxy], ADMIN_SLOT);
    const owner = await new Contract(admin, OWNABLE, provider).owner();
    check(eq(owner, ids.safe), `${proxy} ProxyAdmin owner`, `${owner}`);
    const implNow = await slotAddress(provider, c[proxy], IMPL_SLOT);
    check(eq(implNow, c[impl]), `${proxy} implementation`, `${implNow} (manifest ${c[impl]})`);
    if (m.codehashes[impl]) {
      const h = keccak256(await provider.getCode(implNow));
      check(h === m.codehashes[impl], `${proxy} implementation code`, h === m.codehashes[impl] ? 'matches deployment' : `code hash ${h} differs from deployment`);
    }
  }

  // Timelock
  const tl = new Contract(c.Timelock, TIMELOCK, provider);
  check(eq(await tl.owner(), ids.safe), 'Timelock owner', await tl.owner());

  // AccessManager contracts
  const managed: [string, string[]][] = [
    ['Strategy', [EXECUTOR_ROLE]],
    ['ChainAgent', [EXECUTOR_ROLE, GUARDIAN_ROLE]],
  ];
  if (entry.role === 'hub') managed.push(['TickAccountant', [NAV_UPDATER_ROLE, GUARDIAN_ROLE]], ['EpochVault', [EXECUTOR_ROLE, GUARDIAN_ROLE]]);
  const roleHolder: Record<string, string> = { [EXECUTOR_ROLE]: ids.executor, [GUARDIAN_ROLE]: ids.guardian, [NAV_UPDATER_ROLE]: ids.navUpdater };
  const roleName: Record<string, string> = { [EXECUTOR_ROLE]: 'EXECUTOR', [GUARDIAN_ROLE]: 'GUARDIAN', [NAV_UPDATER_ROLE]: 'NAV_UPDATER' };
  for (const [name, roles] of managed) {
    const ct = new Contract(c[name], ACCESS, provider);
    check(await ct.hasRole(ADMIN_ROLE, ids.safe), `${name} ADMIN = Safe`);
    if (!deployerIsGovernance) check(!(await ct.hasRole(ADMIN_ROLE, m.deployer)), `${name} deployer has no ADMIN`);
    for (const r of [EXECUTOR_ROLE, GUARDIAN_ROLE, NAV_UPDATER_ROLE]) {
      if (eq(roleHolder[r], m.deployer) && stand) continue; // designated holder in the stand profile
      if (await ct.hasRole(r, m.deployer)) check(false, `${name} deployer holds ${roleName[r]}`);
    }
    for (const r of roles) check(await ct.hasRole(r, roleHolder[r]), `${name} ${roleName[r]}`, roleHolder[r]);
    check(eq(await ct.getTimelock(), c.Timelock), `${name} timelock = Timelock`, await ct.getTimelock());
  }

  // transport
  const adapter = new Contract(c.CctpV2Adapter, ADAPTER, provider);
  check(eq(await adapter.governance(), c.Timelock), 'CctpV2Adapter governance = Timelock', await adapter.governance());
  check(eq(await adapter.agent(), c.ChainAgent), 'CctpV2Adapter agent');
  const agent = new Contract(c.ChainAgent, CHAIN_AGENT, provider);
  check(await agent.isAdapter(c.CctpV2Adapter), 'ChainAgent trusts its adapter');
  check(eq(await agent.strategy(), c.Strategy), 'ChainAgent strategy');
  if (entry.role === 'hub') check(eq(await agent.vault(), c.EpochVault), 'hub ChainAgent vault');

  for (const [peerKey, peer] of Object.entries(NETWORKS)) {
    if (peerKey === key) continue;
    const pm = manifests[peerKey];
    if (!pm) {
      check(false, `peer ${peerKey} manifest`, 'missing');
      continue;
    }
    const r = await adapter.remotes(peer.chainId);
    check(r.set && eq(r.adapter, pm.contracts.CctpV2Adapter) && Number(r.domain) === peer.cctp.domain, `adapter remote ${peerKey}`, `${r.adapter} domain ${r.domain}`);
    check(await agent.isPeer(peer.chainId, pm.contracts.ChainAgent), `agent peer ${peerKey}`);
    const limits = entry.routes[peer.chainId.toString()];
    if (limits) {
      const route = await agent.getRoute(routeId(entry.chainId, peer.chainId));
      check(
        eq(route.adapter, c.CctpV2Adapter) && eq(route.dstAgent, pm.contracts.ChainAgent) && route.enabled && BigInt(route.maxPerTransfer) === limits.maxPerTransfer && BigInt(route.capacity) === limits.capacity,
        `route ${key}->${peerKey}`,
        `enabled=${route.enabled} dst=${route.dstAgent}`,
      );
    }
  }

  // strategy wiring and caps
  const strategy = new Contract(c.Strategy, STRATEGY, provider);
  const providers: string[] = await strategy.getProviders();
  const expected = entry.strategy.reusedProviders.map((p) => p.address);
  if (c.CompoundV3Provider) expected.splice(1, 0, c.CompoundV3Provider);
  check(providers.length === expected.length && providers.every((p, i) => eq(p, expected[i])), 'strategy providers', providers.join(','));
  check(eq(await strategy.getEntryProvider(), expected[0]), 'strategy entry provider');
  const labelled: Record<string, string> = Object.fromEntries(entry.strategy.reusedProviders.map((p) => [p.label, p.address]));
  if (c.CompoundV3Provider) labelled.CompoundV3 = c.CompoundV3Provider;
  for (const [label, bps] of Object.entries(entry.strategy.capsBps)) {
    const cap = BigInt(await strategy.getProviderCap(labelled[label]));
    check(cap === BigInt(bps), `strategy cap ${label}`, `${cap} bps`);
  }
  if (c.ProviderManager) {
    const pmgr = new Contract(c.ProviderManager, OWNABLE, provider);
    const owner = await pmgr.owner();
    check(eq(owner, ids.safe), 'ProviderManager owner = Safe', eq(owner, ids.safe) ? owner : `${owner} (Safe must acceptOwnership)`);
  }

  // hub wiring
  if (entry.role === 'hub') {
    const accountant = new Contract(c.TickAccountant, TICK_ACCOUNTANT, provider);
    const vault = new Contract(c.EpochVault, EPOCH_VAULT, provider);
    check(eq(await accountant.vault(), c.EpochVault), 'accountant vault');
    check(eq(await vault.accountant(), c.TickAccountant), 'vault accountant');
    check(eq(await vault.hubAgent(), c.ChainAgent), 'vault hubAgent');
    const chainIds: bigint[] = (await accountant.chainIds()).map((x: bigint) => BigInt(x));
    const want = Object.values(NETWORKS).map((n) => n.chainId).sort((a, b) => (a < b ? -1 : 1));
    check(chainIds.join() === want.join(), 'accountant chain set', chainIds.join(','));
    for (const [netKey, net] of Object.entries(NETWORKS)) {
      const nm = manifests[netKey];
      if (nm) check(await accountant.isAgent(net.chainId, nm.contracts.ChainAgent), `accountant agent ${netKey}`);
    }
    const fees = await accountant.getFees();
    check(eq(fees.treasury, ids.safe), 'fee treasury = Safe', fees.treasury);

    // Parameter coherence. These relations span two contracts and are set by
    // separate Timelock calls, so no contract can enforce them; each violation is
    // a silent stall rather than a revert at the time it is introduced.
    const cfg = await accountant.config();
    const [, down] = await accountant.buckets();
    const epochCfg = await vault.epochConfig();
    const lim = await vault.limits();
    const hubBlockTime = 2n; // Base / OP Stack
    const snapshotCeiling = 256n * hubBlockTime; // EVM blockhash window
    check(
      BigInt(cfg.maxSnapshotAge) < snapshotCeiling,
      'maxSnapshotAge inside the blockhash window',
      `${cfg.maxSnapshotAge}s against a ${snapshotCeiling}s ceiling: older snapshots fail as InvalidHubReference, which does not say why`,
    );
    check(
      BigInt(epochCfg.maxClearingDelay) >= BigInt(cfg.maxTickAge) + BigInt(cfg.maxSnapshotAge),
      'maxClearingDelay covers maxTickAge + maxSnapshotAge',
      `${epochCfg.maxClearingDelay}s against ${BigInt(cfg.maxTickAge) + BigInt(cfg.maxSnapshotAge)}s needed: below it every clear reverts TickNotUsable while ticks still look fresh`,
    );
    check(
      BigInt(lim.instantFee) >= BigInt(down.capacity),
      'instantFee covers the down bucket capacity',
      `${lim.instantFee} against ${down.capacity}: below it, exiting ahead of a pending commitTick that books a loss is risk-free`,
    );
    check(
      BigInt(cfg.minTickInterval) >= BigInt(entry.confirmations) * hubBlockTime,
      'minTickInterval covers the confirmation depth',
      `${cfg.minTickInterval}s against ${BigInt(entry.confirmations) * hubBlockTime}s: below it the hub reference block can precede the previous commit block`,
    );
    const exposure = BigInt(await accountant.maxChainExposure());
    check(true, 'maxChainExposure', exposure === 0n ? 'disabled' : `${(Number(exposure) / 1e16).toFixed(2)}% of gross bid assets per chain`);
  }
  return out;
}
