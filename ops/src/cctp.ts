/**
 * CCTP V2 message helpers and attestation sources.
 *
 * Offsets follow circlefin/evm-cctp-contracts (commit a92a2b4) and are the
 * same ones CctpV2Adapter parses: header 148 bytes, burn body hookData at 228,
 * our hookData = abi.encode(transferId, srcAgent).
 *
 * Attestation sources:
 *  - "iris" (production): Circle's attestation API, v2 messages endpoint.
 *  - "local" (fork rehearsal only): the relayer acts as attester. It fills in
 *    the nonce and finality the way Circle's service does and signs
 *    keccak256(message) with a key that was enabled as attester on the fork
 *    (Attestable._verifyAttestationSignatures uses the raw digest).
 */
import { Contract, Interface, Provider, SigningKey, concat, getBytes, hexlify, keccak256, zeroPadValue, toBeHex } from 'ethers';

export const MESSAGE_SENT_TOPIC = keccak256(new TextEncoder().encode('MessageSent(bytes)'));
const HEADER = 148;
const HOOK = HEADER + 228;

export function transferIdOf(message: string): string {
  const b = getBytes(message);
  if (b.length < HOOK + 64) throw new Error('message too short for Thesauros hookData');
  return hexlify(b.slice(HOOK, HOOK + 32));
}

export function sourceDomainOf(message: string): number {
  const b = getBytes(message);
  return (b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7];
}

export interface Attested {
  message: string;
  attestation: string;
}

/** Circle Iris v2: GET /v2/messages/{sourceDomain}?transactionHash=0x... */
export async function fetchIris(sourceDomain: number, txHash: string, transferId: string): Promise<Attested | undefined> {
  const base = process.env.IRIS_API_URL ?? 'https://iris-api.circle.com';
  const res = await fetch(`${base}/v2/messages/${sourceDomain}?transactionHash=${txHash}`, { signal: AbortSignal.timeout(15_000) });
  if (res.status === 404) return undefined; // not indexed yet
  if (!res.ok) throw new Error(`iris ${res.status}`);
  const body: any = await res.json();
  for (const m of body.messages ?? []) {
    if (m.status !== 'complete' || !m.attestation || m.attestation === 'PENDING') continue;
    if (!m.message || m.message === '0x') continue;
    if (transferIdOf(m.message).toLowerCase() === transferId.toLowerCase()) return { message: m.message, attestation: m.attestation };
  }
  return undefined;
}

/** Fork rehearsal: attest the MessageSent emitted in the source transaction ourselves. */
export async function attestLocally(srcProvider: Provider, transmitter: string, txHash: string, transferId: string, attesterKey: string): Promise<Attested | undefined> {
  const receipt = await srcProvider.getTransactionReceipt(txHash);
  if (!receipt) return undefined;
  const iface = new Interface(['event MessageSent(bytes message)']);
  for (const l of receipt.logs) {
    if (l.address.toLowerCase() !== transmitter.toLowerCase() || l.topics[0] !== MESSAGE_SENT_TOPIC) continue;
    const message: string = iface.parseLog(l)!.args.message;
    if (transferIdOf(message).toLowerCase() !== transferId.toLowerCase()) continue;
    const b = getBytes(message);
    b.set(getBytes(keccak256(transferId)), 12); // nonce, unique per transfer
    b.set(getBytes(zeroPadValue(toBeHex(2000), 4)), 144); // finalityThresholdExecuted = finalized
    const filled = hexlify(b);
    const sig = new SigningKey(attesterKey).sign(keccak256(filled));
    return { message: filled, attestation: concat([sig.r, sig.s, toBeHex(sig.v, 1)]) };
  }
  return undefined;
}

export async function localDomain(provider: Provider, transmitter: string): Promise<number> {
  const c = new Contract(transmitter, ['function localDomain() view returns (uint32)'], provider);
  return Number(await c.localDomain());
}
