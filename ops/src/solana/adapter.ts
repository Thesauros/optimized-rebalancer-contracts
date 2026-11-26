import { PublicKey } from '@solana/web3.js';
import { getAddress, hexlify, ZeroAddress } from 'ethers';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { NETWORKS } from '../../../deploy/crosschain/registry';
import { loadManifest } from '../config';
import { agentAccounts } from './codec';

/** The adapter's immutable endpoints can be derived before either deployment. */
export function planSolanaAdapter(programId: string, seed: string, expectedHubAgent?: string) {
  const base = NETWORKS.base;
  const manifest = loadManifest('base');
  if (manifest.network !== 'base' || manifest.role !== 'hub' || String(manifest.chainId) !== base.chainId.toString())
    throw new Error('expected the Base hub deployment manifest');
  const hubAgent = getAddress(manifest.contracts.ChainAgent);
  if (hubAgent === ZeroAddress || (expectedHubAgent !== undefined && getAddress(expectedHubAgent) !== hubAgent))
    throw new Error('Base manifest/agent mismatch');
  const program = new PublicKey(programId);
  if (program.equals(PublicKey.default)) throw new Error('expected the native agent program ID');
  const { agent, idle } = agentAccounts(program, seed);
  return {
    program: program.toBase58(),
    seed,
    agent: agent.toBase58(),
    idle: idle.toBase58(),
    constructorArgs: {
      asset: base.usdc,
      agent: hubAgent,
      tokenMessenger: base.cctp.tokenMessenger,
      messageTransmitter: base.cctp.messageTransmitter,
      remoteAgent: hexlify(agent.toBytes()),
      remoteTokenAccount: hexlify(idle.toBytes()),
      remoteMint: hexlify(new PublicKey(SOLANA.asset.mint).toBytes()),
      remoteTokenMessenger: hexlify(new PublicKey(SOLANA.cctp.tokenMessenger).toBytes()),
    },
  };
}
