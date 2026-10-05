/**
 * Runtime configuration for the ops services: chains from the deployment
 * registry, addresses from the phase manifests, RPCs and keys from the
 * environment. No hardhat dependency, so services run standalone.
 *
 * Environment:
 *   RPC_<NETWORK>             RPC URL per registry key, e.g. RPC_BASE, RPC_ARBITRUM
 *                             (falls back to BASE_RPC_URL / ARBITRUM_RPC_URL)
 *   RPC_SEND_<NETWORK>        optional: where signed transactions are broadcast.
 *                             Reads stay on RPC_<NETWORK>. Unset = same RPC.
 *   CROSSCHAIN_MANIFEST_DIR   manifest root (default: <repo>/deployments)
 *   CROSSCHAIN_SAFE, CROSSCHAIN_NAV_UPDATER, CROSSCHAIN_EXECUTOR, CROSSCHAIN_GUARDIAN
 *   <ROLE>_PRIVATE_KEY        signer keys per service (see each service)
 */
import fs from 'fs';
import path from 'path';
import { FetchRequest, JsonRpcPayload, JsonRpcProvider, JsonRpcResult, NonceManager, Wallet } from 'ethers';
import { onError, retryTransient, semaphore } from './util';
import { RequestPacer } from './rpc-pacer';
import { NETWORKS, NetworkEntry } from '../../deploy/crosschain/registry';

export interface Manifest {
  network: string;
  chainId: string;
  role: 'hub' | 'spoke';
  profile?: string;
  deployer: string;
  startBlock: number;
  phase: number;
  contracts: Record<string, string>;
  codehashes: Record<string, string>;
  txs: Record<string, string>;
}

export interface Chain {
  key: string;
  entry: NetworkEntry;
  chainId: bigint;
  provider: JsonRpcProvider;
  manifest: Manifest;
}

export function manifestRoot(): string {
  return process.env.CROSSCHAIN_MANIFEST_DIR ?? path.join(__dirname, '..', '..', 'deployments');
}

export function loadManifest(key: string): Manifest {
  const p = path.join(manifestRoot(), key, 'crosschain.json');
  if (!fs.existsSync(p)) throw new Error(`missing manifest ${p}`);
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

export function rpcUrl(key: string): string {
  const direct = process.env[`RPC_${key.toUpperCase()}`];
  if (direct) return direct;
  const legacy = process.env[`${key.toUpperCase()}_RPC_URL`];
  if (legacy) return legacy;
  throw new Error(`no RPC for ${key}: set RPC_${key.toUpperCase()}`);
}

/**
 * Reads from one RPC and broadcasts signed transactions through another. A data
 * provider can accept eth_sendRawTransaction and never propagate it (seen with
 * Moralis during the Base deployment): the service then waits on a transaction
 * the network never saw. The chain's own public endpoint is the reliable path
 * into the sequencer; everything else stays on the provider with the limits and
 * archive data we need.
 */
// One budget across all chains and provider instances in this process (including
// NAV + keeper + relayer). Split the upstream account budget between processes.
const readGate = semaphore(4);
const readPacer = new RequestPacer(Number(process.env.RPC_REQUESTS_PER_SECOND ?? 5));

function readRequest(url: string): FetchRequest {
  const request = new FetchRequest(url);
  request.timeout = 15_000;
  // Ethers' hidden 429 retries otherwise bypass our budget and can block for minutes.
  request.retryFunc = async () => false;
  request.preflightFunc = async (req) => { await readPacer.acquire(); return req; };
  return request;
}

/** Read provider with bounded retries for transient upstream and transport failures. */
export class RetryJsonRpcProvider extends JsonRpcProvider {
  async _send(payload: JsonRpcPayload | Array<JsonRpcPayload>): Promise<Array<JsonRpcResult>> {
    return retryTransient(() => readGate(() => super._send(payload)), 3, 1_000);
  }
}

export class RoutedProvider extends RetryJsonRpcProvider {
  readonly sender: JsonRpcProvider;

  constructor(readUrl: string, sendUrl: string, chainId: number) {
    super(readRequest(readUrl), chainId, { staticNetwork: true, batchMaxCount: 1 });
    this.sender = new JsonRpcProvider(sendUrl, chainId, { staticNetwork: true, batchMaxCount: 1 });
  }

  async _send(payload: JsonRpcPayload | Array<JsonRpcPayload>): Promise<Array<JsonRpcResult>> {
    const list = Array.isArray(payload) ? payload : [payload];
    if (list.length > 0 && list.every((p) => p.method === 'eth_sendRawTransaction')) return this.sender._send(payload);
    return super._send(payload);
  }
}

export function providerFor(key: string, chainId: bigint): JsonRpcProvider {
  const send = process.env[`RPC_SEND_${key.toUpperCase()}`];
  const read = rpcUrl(key);
  if (send && send !== read) return new RoutedProvider(read, send, Number(chainId));
  return new RetryJsonRpcProvider(readRequest(read), Number(chainId), { staticNetwork: true, batchMaxCount: 1 });
}

export function loadChains(): Chain[] {
  return Object.entries(NETWORKS).map(([key, entry]) => {
    const provider = providerFor(key, entry.chainId);
    return { key, entry, chainId: entry.chainId, provider, manifest: loadManifest(key) };
  });
}

export function hubOf(chains: Chain[]): Chain {
  const hub = chains.find((c) => c.entry.role === 'hub');
  if (!hub) throw new Error('no hub in registry');
  return hub;
}

const signers = new Map<string, NonceManager>();

/**
 * One NonceManager per (address, chain): services send several transactions in
 * a row from the same key, so nonces are tracked locally and re-synced from the
 * chain after any failed iteration. Keyed by address, not by variable name: on
 * the stand NAV_UPDATER, KEEPER, RELAYER and EXECUTOR are one key, and they
 * share one counter only when they run in one process (`operators.ts`).
 */
export function signerFor(chain: Chain, envKey: string): NonceManager {
  const pk = process.env[envKey];
  if (!pk) throw new Error(`${envKey} is not set`);
  const cacheKey = `${new Wallet(pk).address}:${chain.chainId}`;
  let s = signers.get(cacheKey);
  if (!s) {
    s = new NonceManager(new Wallet(pk, chain.provider));
    signers.set(cacheKey, s);
    onError(() => s!.reset());
  }
  return s;
}

export function envNumber(key: string, fallback: number): number {
  const v = process.env[key];
  return v === undefined || v === '' ? fallback : Number(v);
}

export function identities() {
  return {
    safe: process.env.CROSSCHAIN_SAFE ?? '',
    navUpdater: process.env.CROSSCHAIN_NAV_UPDATER ?? '',
    executor: process.env.CROSSCHAIN_EXECUTOR ?? '',
    guardian: process.env.CROSSCHAIN_GUARDIAN ?? '',
  };
}
