import { Contract, getAddress, Interface, ZeroAddress } from 'ethers';
import { SOLANA, type SolanaManifest } from '../../../deploy/crosschain/native-registry';
import { routeId } from '../../../deploy/crosschain/registry';
import { CHAIN_AGENT, TICK_ACCOUNTANT } from '../abi';
import type { Chain } from '../config';
import { nativeRouteLimits, type NativeRouteLimits } from './prepare';

const governance = new Interface([
  'function setAdapter(address,bool)',
  'function setPeer(uint64,address,bool)',
  'function addRoute(bytes32,address,uint64,address,uint16,uint128,uint128,uint128)',
  'function setAgent(uint64,address,bool)',
  'function setChains(uint64[])',
]);

/** Prepare only the outstanding registrations at one observed Base block. */
export async function planHubActivation(
  hub: Chain,
  manifest: Pick<SolanaManifest, 'hubAgent' | 'hubAdapter'>,
  alias: string,
  limits: NativeRouteLimits,
) {
  if (getAddress(manifest.hubAgent) !== getAddress(hub.manifest.contracts.ChainAgent))
    throw new Error('Solana manifest hubAgent differs from the Base deployment');
  const { max, cap, refill, feeBps } = nativeRouteLimits(limits);
  const accountantAddress = hub.manifest.contracts.TickAccountant;
  const accountant = new Contract(accountantAddress, TICK_ACCOUNTANT, hub.provider);
  const agent = new Contract(manifest.hubAgent, CHAIN_AGENT, hub.provider);
  const nativeId = SOLANA.accountingId;
  const id = routeId(hub.chainId, nativeId);
  const at = { blockTag: await hub.provider.getBlockNumber() };
  const [chainIds, alreadyAgent, alreadyPeer, alreadyAdapter, route] = await Promise.all([
    accountant.chainIds(at) as Promise<bigint[]>,
    accountant.isAgent(nativeId, alias, at),
    agent.isPeer(nativeId, alias, at),
    agent.isAdapter(manifest.hubAdapter, at),
    agent.getRoute(id, at),
  ]);
  const actions: { label: string; target: string; data: string; value: string }[] = [];
  function add(target: string, label: string, method: string, args: unknown[]) {
    actions.push({ label: `${label}.${method}`, target, data: governance.encodeFunctionData(method, args), value: '0' });
  }
  if (!alreadyAdapter) add(manifest.hubAgent, 'ChainAgent', 'setAdapter', [manifest.hubAdapter, true]);
  if (!alreadyPeer) add(manifest.hubAgent, 'ChainAgent', 'setPeer', [nativeId, alias, true]);
  if (route.adapter === ZeroAddress) {
    add(manifest.hubAgent, 'ChainAgent', 'addRoute', [id, manifest.hubAdapter, nativeId, alias, feeBps, max, cap, refill]);
  } else if (
    getAddress(route.adapter) !== getAddress(manifest.hubAdapter) ||
    route.dstChainId !== nativeId || getAddress(route.dstAgent) !== getAddress(alias) || !route.enabled ||
    route.maxFeeBps !== BigInt(feeBps) || route.maxPerTransfer !== max ||
    route.capacity !== cap || route.refillPerSecond !== refill
  ) {
    throw new Error('Existing Base-to-Solana route differs from the requested activation. Review its endpoints, enabled state and limits.');
  }
  const wanted = chainIds.includes(nativeId) ? chainIds : [...chainIds, nativeId].sort((a, b) => (a < b ? -1 : 1));
  // TickAccountant.setAgent rejects an unregistered chain. Preserve every current member when adding Solana.
  if (!chainIds.includes(nativeId)) add(accountantAddress, 'TickAccountant', 'setChains', [wanted]);
  if (!alreadyAgent) add(accountantAddress, 'TickAccountant', 'setAgent', [nativeId, alias, true]);
  return {
    agent: manifest.hubAgent,
    adapter: manifest.hubAdapter,
    peer: alias,
    routeId: id,
    chains: wanted.map(String),
    prerequisite: 'Deploy/verify CctpSolanaAdapter first; activate only after native checkpoint, lookup table and relayer readiness. These are unsigned Timelock actions.',
    actions,
    alreadyPeer,
  };
}
