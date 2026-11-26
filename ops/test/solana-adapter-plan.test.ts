import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PublicKey } from '@solana/web3.js';
import { getBytes } from 'ethers';
import { SOLANA } from '../../deploy/crosschain/native-registry';
import { NETWORKS } from '../../deploy/crosschain/registry';
import { loadManifest } from '../src/config';
import { planSolanaAdapter } from '../src/solana/adapter';

const program = '3qbR1eZRqXUWroWKKYhbDmR3FfqTHfqSU8zZSxtANzYh';
const seed = '0x' + '0d'.repeat(32);

test('first deployment derives full-width adapter endpoints before a native manifest exists', () => {
  const plan = planSolanaAdapter(program, seed);
  const args = plan.constructorArgs;
  assert.equal(plan.agent, 'F9HTYdTZQMC3Z9jTi8Do1UTmNb9ZkLpFfWSfyACe2ABL');
  assert.equal(plan.idle, '97oDf1hktXFCSp9vMzZFSDhczjHsM2stMpexfvWGVioT');
  assert.equal(new PublicKey(getBytes(args.remoteAgent)).toBase58(), plan.agent);
  assert.equal(new PublicKey(getBytes(args.remoteTokenAccount)).toBase58(), plan.idle);
  assert.equal(new PublicKey(getBytes(args.remoteMint)).toBase58(), SOLANA.asset.mint);
  assert.equal(new PublicKey(getBytes(args.remoteTokenMessenger)).toBase58(), SOLANA.cctp.tokenMessenger);
  assert.equal(args.agent, loadManifest('base').contracts.ChainAgent);
  assert.equal(args.asset, NETWORKS.base.usdc);
  assert.equal(args.tokenMessenger, NETWORKS.base.cctp.tokenMessenger);
  assert.equal(args.messageTransmitter, NETWORKS.base.cctp.messageTransmitter);
  assert.deepEqual(planSolanaAdapter(program, seed, args.agent), plan);
});

test('adapter preparation rejects a mismatched hub, system program and short seed', () => {
  assert.throws(() => planSolanaAdapter(program, seed, NETWORKS.base.usdc), /Base manifest\/agent mismatch/);
  assert.throws(() => planSolanaAdapter(PublicKey.default.toBase58(), seed), /program ID/);
  assert.throws(() => planSolanaAdapter(program, '0x01'), /bytes32/);
});
