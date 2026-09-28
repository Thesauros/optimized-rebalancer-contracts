/**
 * Phase 5 (after handover): turn "registry vs chain" differences into
 * governance transactions, instead of sending anything.
 *
 *   npx hardhat run deploy/crosschain/05-governance-plan.ts --network base
 *
 * Output: deployments/<network>/governance-plan-<timestamp>.json with
 *   - timelockCalls: every Timelock-owned change (routes, peers, adapter
 *     remotes, provider caps, accountant chain set and agents, hub agent);
 *   - safeQueueBatch / safeExecuteBatch: Safe Transaction Builder files that
 *     call Timelock.queue(...) now and Timelock.execute(...) after the delay;
 *   - safeDirectBatch: ADMIN_ROLE actions the Safe sends directly (role grants).
 * Used when adding a network to the registry: run it on every existing network
 * after the new network has completed phases 1-3.
 */
import fs from 'fs';
import path from 'path';
import { ethers } from 'hardhat';
import { HUB_PARAMS, NETWORKS, PROFILE, identities, routeId } from './registry';
import { EXECUTOR_ROLE, GUARDIAN_ROLE, NAV_UPDATER_ROLE, banner, currentEntry, manifestRoot, peers, requireManifest } from './lib';

interface Call {
  target: string;
  signature: string;
  args: unknown[];
  description: string;
}

async function main() {
  const [key, entry] = await currentEntry();
  const ids = identities();
  banner('Phase 5 governance plan');
  const m = requireManifest(key, 3);
  const c = m.contracts;
  const timelockCalls: Call[] = [];
  const directCalls: Call[] = [];
  const tl = (target: string, signature: string, args: unknown[], description: string) => timelockCalls.push({ target, signature, args, description });

  const agent = await ethers.getContractAt('ChainAgent', c.ChainAgent);
  const adapter = await ethers.getContractAt('CctpV2Adapter', c.CctpV2Adapter);
  const strategy = await ethers.getContractAt('Rebalancer', c.Strategy);

  for (const [peerKey, peer] of peers(key)) {
    let pm;
    try {
      pm = requireManifest(peerKey, 1);
    } catch {
      console.log(`  - ${peerKey}: no manifest yet, skipped`);
      continue;
    }
    const remote = await adapter.remotes(peer.chainId);
    if (!remote.set || remote.adapter.toLowerCase() !== pm.contracts.CctpV2Adapter.toLowerCase() || Number(remote.domain) !== peer.cctp.domain) {
      tl(c.CctpV2Adapter, 'setRemote(uint64,uint32,address)', [peer.chainId, peer.cctp.domain, pm.contracts.CctpV2Adapter], `adapter remote ${peerKey}`);
    }
    if (!(await agent.isPeer(peer.chainId, pm.contracts.ChainAgent))) {
      tl(c.ChainAgent, 'setPeer(uint64,address,bool)', [peer.chainId, pm.contracts.ChainAgent, true], `agent peer ${peerKey}`);
    }
    const limits = entry.routes[peer.chainId.toString()];
    if (!limits) continue;
    const rid = routeId(entry.chainId, peer.chainId);
    const route = await agent.getRoute(rid);
    if (route.adapter === ethers.ZeroAddress) {
      tl(
        c.ChainAgent,
        'addRoute(bytes32,address,uint64,address,uint16,uint128,uint128,uint128)',
        [rid, c.CctpV2Adapter, peer.chainId, pm.contracts.ChainAgent, limits.maxFeeBps, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond],
        `route ${key}->${peerKey}`,
      );
    } else if (
      route.maxPerTransfer !== limits.maxPerTransfer ||
      route.capacity !== limits.capacity ||
      route.refillPerSecond !== limits.refillPerSecond ||
      Number(route.maxFeeBps) !== limits.maxFeeBps
    ) {
      tl(
        c.ChainAgent,
        'configureRoute(bytes32,bool,uint16,uint128,uint128,uint128)',
        [rid, true, limits.maxFeeBps, limits.maxPerTransfer, limits.capacity, limits.refillPerSecond],
        `route limits ${key}->${peerKey}`,
      );
    }
  }

  const labelled: Record<string, string> = Object.fromEntries(entry.strategy.reusedProviders.map((p) => [p.label, p.address]));
  if (c.CompoundV3Provider) labelled.CompoundV3 = c.CompoundV3Provider;
  for (const [label, bps] of Object.entries(entry.strategy.capsBps)) {
    const current = BigInt(await strategy.getProviderCap(labelled[label]));
    if (current !== BigInt(bps)) {
      // lowering (or setting from uncapped) is an ADMIN action; raising/removing needs the Timelock
      const lowering = bps !== 0 && (current === 0n || BigInt(bps) <= current);
      const call = { target: c.Strategy, signature: 'setProviderCap(address,uint256)', args: [labelled[label], bps], description: `cap ${label} ${current} -> ${bps} bps` };
      (lowering ? directCalls : timelockCalls).push(call);
    }
  }

  if (entry.role === 'hub') {
    const accountant = await ethers.getContractAt('TickAccountant', c.TickAccountant);
    const want = Object.values(NETWORKS).map((n) => n.chainId).sort((a, b) => (a < b ? -1 : 1));
    const have: bigint[] = (await accountant.chainIds()).map((x: bigint) => BigInt(x));
    // agents first, then the chain set, so the first tick after execution can include the new chain
    for (const [netKey, net] of Object.entries(NETWORKS)) {
      let nm;
      try {
        nm = requireManifest(netKey, 1);
      } catch {
        continue;
      }
      if (!have.includes(net.chainId) || !(await accountant.isAgent(net.chainId, nm.contracts.ChainAgent))) {
        if (have.includes(net.chainId)) tl(c.TickAccountant, 'setAgent(uint64,address,bool)', [net.chainId, nm.contracts.ChainAgent, true], `accountant agent ${netKey}`);
      }
    }
    if (have.join() !== want.join()) {
      tl(c.TickAccountant, 'setChains(uint64[])', [want], `accountant chain set ${have.join(',')} -> ${want.join(',')}`);
      for (const [netKey, net] of Object.entries(NETWORKS)) {
        if (have.includes(net.chainId)) continue;
        const nm = requireManifest(netKey, 1);
        tl(c.TickAccountant, 'setAgent(uint64,address,bool)', [net.chainId, nm.contracts.ChainAgent, true], `accountant agent ${netKey} (after setChains)`);
      }
    }
    const vault = await ethers.getContractAt('EpochVault', c.EpochVault);

    // protocol parameters of the selected profile (e.g. stand -> production limits)
    const a = HUB_PARAMS.accountant;
    const wantCfg = [a.minTickInterval, a.maxSnapshotAge, a.maxTickAge, a.maxTransit, a.maxSpread, a.depositClearingMaxDown, a.maxInFlightRatio, a.maxOverdueInFlight];
    const haveCfg = await accountant.config();
    if (wantCfg.some((v, i) => BigInt(haveCfg[i]) !== v)) tl(c.TickAccountant, 'setConfig((uint64,uint64,uint64,uint64,uint128,uint128,uint128,uint128))', [wantCfg], `accountant config -> ${PROFILE}`);
    // kept out of Config: see the note on COMMON_ACCOUNTANT.maxChainExposure
    if (BigInt(await accountant.maxChainExposure()) !== a.maxChainExposure) {
      tl(
        c.TickAccountant,
        'setMaxChainExposure(uint128)',
        [a.maxChainExposure],
        `max chain exposure -> ${a.maxChainExposure === 0n ? 'disabled' : `${(Number(a.maxChainExposure) / 1e16).toFixed(2)}% of gross assets per chain`}`,
      );
    }
    const [up, down] = await accountant.buckets();
    const U = HUB_PARAMS.upBucket;
    const D = HUB_PARAMS.downBucket;
    if (BigInt(up.capacity) !== U.capacity || BigInt(up.refillPerSecond) !== U.refillPerSecond || BigInt(down.capacity) !== D.capacity || BigInt(down.refillPerSecond) !== D.refillPerSecond) {
      tl(c.TickAccountant, 'setBuckets((uint128,uint128,uint128,uint64),(uint128,uint128,uint128,uint64))', [[U.capacity, U.refillPerSecond, 0, 0], [D.capacity, D.refillPerSecond, 0, 0]], `rate buckets -> ${PROFILE}`);
    }
    const e = HUB_PARAMS.epoch;
    const wantEpoch = [e.minDuration, e.maxDuration, e.minTicks, e.maxClearingDelay];
    const haveEpoch = await vault.epochConfig();
    if (wantEpoch.some((v, i) => BigInt(haveEpoch[i]) !== v)) tl(c.EpochVault, 'setEpochConfig((uint64,uint64,uint64,uint64))', [wantEpoch], `epoch config -> ${PROFILE}`);
    const l = HUB_PARAMS.limits;
    const wantLimits = [l.minDeposit, l.maxEpochDeposits, l.minimumBuffer, l.minBufferRatio, l.maxInstantWithdrawal, l.dailyInstantLimit, l.instantFee, l.instantMaxTickAge];
    const haveLimits = await vault.limits();
    if (wantLimits.some((v, i) => BigInt(haveLimits[i]) !== v)) tl(c.EpochVault, 'setLimits((uint128,uint128,uint128,uint128,uint128,uint128,uint64,uint64))', [wantLimits], `vault limits -> ${PROFILE}`);

    for (const [ct, name, role, roleName, holder] of [
      [accountant, 'TickAccountant', NAV_UPDATER_ROLE, 'NAV_UPDATER', ids.navUpdater],
      [accountant, 'TickAccountant', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian],
      [vault, 'EpochVault', EXECUTOR_ROLE, 'EXECUTOR', ids.executor],
      [vault, 'EpochVault', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian],
    ] as const) {
      if (!(await (ct as any).hasRole(role, holder))) directCalls.push({ target: await (ct as any).getAddress(), signature: 'grantRole(bytes32,address)', args: [role, holder], description: `${name} ${roleName} -> ${holder}` });
    }
  }
  for (const [ct, name, role, roleName, holder] of [
    [agent, 'ChainAgent', EXECUTOR_ROLE, 'EXECUTOR', ids.executor],
    [agent, 'ChainAgent', GUARDIAN_ROLE, 'GUARDIAN', ids.guardian],
    [strategy, 'Strategy', EXECUTOR_ROLE, 'EXECUTOR', ids.executor],
  ] as const) {
    if (!(await (ct as any).hasRole(role, holder))) directCalls.push({ target: await (ct as any).getAddress(), signature: 'grantRole(bytes32,address)', args: [role, holder], description: `${name} ${roleName} -> ${holder}` });
  }

  // encode
  const timelock = await ethers.getContractAt('Timelock', c.Timelock);
  const delay = BigInt(await timelock.delay());
  const latest = await ethers.provider.getBlock('latest');
  const eta = BigInt(latest!.timestamp) + delay + BigInt(process.env.GOVERNANCE_ETA_MARGIN ?? '3600');
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const encodeArgs = (sig: string, args: unknown[]) => coder.encode(ethers.FunctionFragment.from(sig).inputs, args);
  const chainId = entry.chainId.toString();
  const batch = (name: string, txs: { to: string; data: string }[]) => ({
    version: '1.0',
    chainId,
    createdAt: Date.now(),
    meta: { name, description: `Thesauros cross-chain ${key}: ${name}` },
    transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })),
  });
  const queueTxs = timelockCalls.map((call) => ({ to: c.Timelock, data: timelock.interface.encodeFunctionData('queue', [call.target, 0, call.signature, encodeArgs(call.signature, call.args), eta]) }));
  const executeTxs = timelockCalls.map((call) => ({ to: c.Timelock, data: timelock.interface.encodeFunctionData('execute', [call.target, 0, call.signature, encodeArgs(call.signature, call.args), eta]) }));
  const directTxs = directCalls.map((call) => ({ to: call.target, data: new ethers.Interface([`function ${call.signature}`]).encodeFunctionData(call.signature.split('(')[0], call.args) }));

  const plan = {
    network: key,
    generatedAt: new Date().toISOString(),
    timelock: c.Timelock,
    eta: eta.toString(),
    etaIso: new Date(Number(eta) * 1000).toISOString(),
    timelockCalls: timelockCalls.map((x) => ({ ...x, args: x.args.map(String) })),
    directCalls: directCalls.map((x) => ({ ...x, args: x.args.map(String) })),
    safeQueueBatch: batch('queue', queueTxs),
    safeExecuteBatch: batch(`execute after ${new Date(Number(eta) * 1000).toISOString()}`, executeTxs),
    safeDirectBatch: batch('direct ADMIN actions', directTxs),
  };
  const out = path.join(manifestRoot(), key, `governance-plan-${Date.now()}.json`);
  fs.writeFileSync(out, JSON.stringify(plan, (_k, v) => (typeof v === 'bigint' ? v.toString() : v), 2) + '\n');
  for (const x of timelockCalls) console.log(`  timelock: ${x.description}`);
  for (const x of directCalls) console.log(`  safe:     ${x.description}`);
  if (!timelockCalls.length && !directCalls.length) console.log('  nothing to change: chain matches the registry');
  console.log(`\nPlan written to ${out}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
