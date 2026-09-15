/**
 * CCTP Relay Keeper — polls Circle's attestation service and delivers
 * minted USDC to the CCTPRelayReceiver on the destination chain.
 *
 * Flow:
 *   1. Watch CCTPBurn events on the source chain adapter
 *   2. Poll Circle's attestation API for each burn nonce
 *   3. When attestation is available, call relay.deliver() on destination
 *
 * Usage:
 *   npx hardhat run scripts/cctp-relay-keeper.ts --network base
 *
 * Environment variables:
 *   CCTP_ADAPTER_SOURCE     — CCTPMeshBridgeAdapter address on source chain
 *   CCTP_RELAY_DEST         — CCTPRelayReceiver address on destination chain
 *   CCTP_DEST_RPC           — RPC URL for destination chain
 *   CCTP_SOURCE_DOMAIN      — Source domain ID (6=Base, 3=Arbitrum)
 *   CCTP_DEST_DOMAIN        — Destination domain ID
 *   RELAY_KEEPER_KEY        — Private key for the relay keeper
 *   POLL_INTERVAL_MS        — Attestation poll interval (default: 10000)
 *   CCTP_API_URL            — Circle attestation API (default: https://iris-api.circle.com/v2)
 */

import { ethers } from 'hardhat';

const CCTP_API = process.env.CCTP_API_URL || 'https://iris-api.circle.com/v2';
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL_MS || '10000');
const SOURCE_DOMAIN = parseInt(process.env.CCTP_SOURCE_DOMAIN || '6');
const DEST_DOMAIN = parseInt(process.env.CCTP_DEST_DOMAIN || '3');

interface BurnEvent {
  transferId: string;
  nonce: bigint;
  amount: bigint;
  blockNumber: number;
  txHash: string;
}

async function fetchAttestation(messageHash: string): Promise<{ message: string; attestation: string } | null> {
  try {
    const url = `${CCTP_API}/messages/${SOURCE_DOMAIN}?message=${messageHash}`;
    const response = await fetch(url);
    if (!response.ok) return null;
    const data = await response.json();
    if (data.message && data.attestation) {
      return { message: data.message, attestation: data.attestation };
    }
    return null;
  } catch {
    return null;
  }
}

async function main() {
  const [signer] = await ethers.getSigners();
  console.log('=== CCTP Relay Keeper ===');
  console.log('Keeper:', signer.address);
  console.log('Source domain:', SOURCE_DOMAIN);
  console.log('Dest domain:', DEST_DOMAIN);
  console.log('API:', CCTP_API);
  console.log('Poll interval:', POLL_INTERVAL, 'ms');
  console.log('');

  const adapterAddr = process.env.CCTP_ADAPTER_SOURCE;
  const relayAddr = process.env.CCTP_RELAY_DEST;
  const destRpc = process.env.CCTP_DEST_RPC;

  if (!adapterAddr || !relayAddr || !destRpc) {
    console.error('Missing env: CCTP_ADAPTER_SOURCE, CCTP_RELAY_DEST, CCTP_DEST_RPC');
    process.exit(1);
  }

  // Connect to source chain (current network)
  const adapter = await ethers.getContractAt('CCTPMeshBridgeAdapter', adapterAddr);

  // Connect to destination chain
  const destProvider = new ethers.JsonRpcProvider(destRpc);
  const destSigner = new ethers.Wallet(process.env.RELAY_KEEPER_KEY || '', destProvider);
  const relay = new ethers.Contract(relayAddr, [
    'function deliver(bytes message, bytes attestation, bytes32 transferId, uint64 srcChainId, bytes32 srcPeer)',
    'function keeper() view returns (address)',
  ], destSigner);

  console.log('Source adapter:', adapterAddr);
  console.log('Dest relay:', relayAddr);
  console.log('Dest keeper:', await relay.keeper());
  console.log('');

  // Track pending burns
  const pendingBurns = new Map<string, BurnEvent>();

  // Listen for CCTPBurn events
  console.log('Listening for CCTPBurn events...');
  adapter.on('CCTPBurn', async (transferId: string, nonce: bigint, asset: string, amount: bigint, destDomain: bigint, relayPeer: string, event: any) => {
    console.log(`[BURN] transferId=${transferId} nonce=${nonce} amount=${amount} block=${event.log.blockNumber}`);
    pendingBurns.set(transferId, {
      transferId,
      nonce,
      amount,
      blockNumber: event.log.blockNumber,
      txHash: event.log.transactionHash,
    });
  });

  // Poll for attestations
  console.log('Starting attestation poll loop...');
  while (true) {
    for (const [transferId, burn] of pendingBurns) {
      try {
        // Compute message hash (Circle uses keccak256 of the message bytes)
        // For the API, we need the actual message bytes from the MessageSent event
        // In production, we'd parse the MessageSent event from the source chain
        // For now, we use the nonce-based lookup
        const messageHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['uint64'], [burn.nonce]));

        const attestation = await fetchAttestation(messageHash);
        if (attestation) {
          console.log(`[ATTESTED] transferId=${transferId} nonce=${burn.nonce}`);

          // Determine srcPeer based on mode
          // For destination relay (MODE_CUSTODIAN): srcPeer is not used by onBridgeIn
          // For source relay (MODE_NODE): srcPeer is the custodian address
          const srcPeer = ethers.zeroPadValue(ethers.ZeroAddress, 32);

          try {
            const tx = await relay.deliver(
              attestation.message,
              attestation.attestation,
              transferId,
              SOURCE_DOMAIN,
              srcPeer
            );
            console.log(`[DELIVERED] transferId=${transferId} tx=${tx.hash}`);
            await tx.wait();
            console.log(`[CONFIRMED] transferId=${transferId}`);
            pendingBurns.delete(transferId);
          } catch (err: any) {
            console.error(`[DELIVER FAILED] transferId=${transferId}:`, err.message);
          }
        } else {
          // Still waiting for attestation
          const age = Date.now() - burn.blockNumber * 2000; // rough estimate
          if (age > 300000) { // 5 minutes
            console.log(`[WAITING] transferId=${transferId} nonce=${burn.nonce} (attestation pending)`);
          }
        }
      } catch (err: any) {
        console.error(`[ERROR] transferId=${transferId}:`, err.message);
      }
    }

    await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL));
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
