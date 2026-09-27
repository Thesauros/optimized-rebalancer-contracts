/**
 * Shared helpers for the cross-chain deployment phases.
 *
 * State lives in a per-network manifest, deployments/<network>/crosschain.json
 * (override the root with CROSSCHAIN_MANIFEST_DIR for rehearsals). Every phase
 * is idempotent: it reads the manifest and the chain, and only sends what is
 * still missing, so a failed run can be re-run.
 */
import fs from 'fs';
import path from 'path';
import { ethers, network } from 'hardhat';
import type { ContractTransactionResponse, Signer } from 'ethers';
import { NETWORKS, NetworkEntry, entryByChainId } from './registry';

export const ADMIN_ROLE = ethers.ZeroHash;
export const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');
export const GUARDIAN_ROLE = ethers.id('GUARDIAN_ROLE');
export const NAV_UPDATER_ROLE = ethers.id('NAV_UPDATER_ROLE');

// ERC-1967 slots
export const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
export const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

export interface Manifest {
  network: string;
  chainId: string;
  role: 'hub' | 'spoke';
  deployer: string;
  startBlock: number;
  phase: number;
  contracts: Record<string, string>;
  /** keccak256 of runtime code per implementation / immutable contract, for drift checks */
  codehashes: Record<string, string>;
  txs: Record<string, string>;
}

export function manifestRoot(): string {
  return process.env.CROSSCHAIN_MANIFEST_DIR ?? path.join(__dirname, '..', '..', 'deployments');
}

export function manifestPath(networkKey: string): string {
  return path.join(manifestRoot(), networkKey, 'crosschain.json');
}

export function readManifest(networkKey: string): Manifest | undefined {
  const p = manifestPath(networkKey);
  if (!fs.existsSync(p)) return undefined;
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

export function writeManifest(m: Manifest): void {
  const p = manifestPath(m.network);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + '\n');
}

export function requireManifest(networkKey: string, minPhase: number): Manifest {
  const m = readManifest(networkKey);
  if (!m) throw new Error(`no cross-chain manifest for ${networkKey} at ${manifestPath(networkKey)}`);
  if (m.phase < minPhase) throw new Error(`${networkKey} is at phase ${m.phase}, need >= ${minPhase}`);
  return m;
}

/** Registry entry of the network hardhat is connected to (matched by chain id). */
export async function currentEntry(): Promise<[string, NetworkEntry]> {
  const { chainId } = await ethers.provider.getNetwork();
  return entryByChainId(chainId);
}

export function peers(selfKey: string): [string, NetworkEntry][] {
  return Object.entries(NETWORKS).filter(([k]) => k !== selfKey);
}

export async function send(label: string, tx: Promise<ContractTransactionResponse>): Promise<string> {
  const sent = await tx;
  const receipt = await sent.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`${label}: transaction failed (${sent.hash})`);
  console.log(`  ✓ ${label}  ${sent.hash}`);
  return sent.hash;
}

export async function codehash(address: string): Promise<string> {
  return ethers.keccak256(await ethers.provider.getCode(address));
}

export async function proxyAdminOf(proxy: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxy, ADMIN_SLOT);
  return ethers.getAddress('0x' + raw.slice(26));
}

export async function implementationOf(proxy: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxy, IMPLEMENTATION_SLOT);
  return ethers.getAddress('0x' + raw.slice(26));
}

export async function deployer(): Promise<Signer> {
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error('no signer: set DEPLOYER_PRIVATE_KEY for this network');
  return signer;
}

export function banner(title: string): void {
  console.log(`\n=== ${title} on ${network.name} ===`);
}

/** Grants `role` to `account` on an AccessManager contract if missing. */
export async function ensureRole(contract: any, name: string, role: string, roleName: string, account: string): Promise<void> {
  if (await contract.hasRole(role, account)) return;
  await send(`${name}.grantRole(${roleName}, ${account})`, contract.grantRole(role, account));
}

export function sameAddress(a?: string, b?: string): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}
