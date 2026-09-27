/**
 * Runtime configuration for the ops services: chains from the deployment
 * registry, addresses from the phase manifests, RPCs and keys from the
 * environment. No hardhat dependency, so services run standalone.
 *
 * Environment:
 *   RPC_<NETWORK>             RPC URL per registry key, e.g. RPC_BASE, RPC_ARBITRUM
 *                             (falls back to BASE_RPC_URL / ARBITRUM_RPC_URL)
 *   CROSSCHAIN_MANIFEST_DIR   manifest root (default: <repo>/deployments)
 *   CROSSCHAIN_SAFE, CROSSCHAIN_NAV_UPDATER, CROSSCHAIN_EXECUTOR, CROSSCHAIN_GUARDIAN
 *   <ROLE>_PRIVATE_KEY        signer keys per service (see each service)
 */
import fs from 'fs';
import path from 'path';
import { JsonRpcProvider, NonceManager, Wallet } from 'ethers';
import { onError } from './util';
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

export function loadChains(): Chain[] {
  return Object.entries(NETWORKS).map(([key, entry]) => {
    const provider = new JsonRpcProvider(rpcUrl(key), Number(entry.chainId), { staticNetwork: true, batchMaxCount: 1 });
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
 * One NonceManager per (key, chain): services send several transactions in a
 * row from the same key, so nonces are tracked locally and re-synced from the
 * chain after any failed iteration.
 */
export function signerFor(chain: Chain, envKey: string): NonceManager {
  const pk = process.env[envKey];
  if (!pk) throw new Error(`${envKey} is not set`);
  const cacheKey = `${envKey}:${chain.key}`;
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
