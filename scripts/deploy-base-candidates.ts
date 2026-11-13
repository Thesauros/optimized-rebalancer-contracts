/**
 * Deploys the three reviewed Base upgrade candidates from the preparation
 * bundle's creation data and asserts each deployed runtime against the
 * reviewed codehash before recording anything.
 *
 * Live writes: yes, three contract creations on Base mainnet. No governance,
 * upgrade or provider registration happens here.
 */
import fs from 'node:fs';
import path from 'node:path';
import { JsonRpcProvider, Wallet, keccak256, getAddress } from 'ethers';

const ROOT = path.resolve(__dirname, '..');
const BUNDLE = path.join(ROOT, 'changes/base-crosschain-upgrade/base-upgrade-plan.json');
const REVIEWED = path.join(ROOT, 'changes/base-crosschain-upgrade/preparation.json');
const OUT = path.join(ROOT, 'changes/base-crosschain-upgrade/base-candidate-deployment.json');
const RPC = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const ORDER = ['Rebalancer', 'FluidProvider', 'MorphoV2Provider'];

async function main() {
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key) throw new Error('DEPLOYER_PRIVATE_KEY is required');
  const bundle = JSON.parse(fs.readFileSync(BUNDLE, 'utf8'));
  const reviewed = JSON.parse(fs.readFileSync(REVIEWED, 'utf8'));
  const provider = new JsonRpcProvider(RPC, 8453, { staticNetwork: true, batchMaxCount: 1 });
  const wallet = new Wallet(key, provider);
  const deployer = wallet.address;
  if (getAddress(deployer) !== getAddress('0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D')) {
    throw new Error(`Unexpected deployer ${deployer}`);
  }
  const balance = await provider.getBalance(deployer);
  const nonce = await provider.getTransactionCount(deployer, 'pending');
  console.log(JSON.stringify({ deployer, balanceEth: Number(balance) / 1e18, nonce, rpc: new URL(RPC).host }));

  const results: Record<string, unknown> = {};
  for (const name of ORDER) {
    const candidate = bundle.candidates.find((c: any) => c.name === name);
    const reference = reviewed.candidates.find((c: any) => c.name === name);
    if (!candidate || !reference) throw new Error(`Missing candidate ${name}`);
    const creation = candidate.unsignedDeployment.data as string;
    if (candidate.unsignedDeployment.chainId !== 8453) throw new Error(`${name}: not Base`);
    if (keccak256(creation) !== reference.creationCodeHash) {
      throw new Error(`${name}: creation data does not match the reviewed creationCodeHash`);
    }
    if (candidate.expectedRuntimeHash !== reference.expectedRuntimeHash) {
      throw new Error(`${name}: expected runtime hash drifted from the reviewed bundle`);
    }
    const sent = await wallet.sendTransaction({ data: creation, chainId: 8453 });
    console.log(JSON.stringify({ name, tx: sent.hash, waiting: true }));
    const receipt = await sent.wait(2);
    if (!receipt || receipt.status !== 1) throw new Error(`${name}: deployment reverted`);
    const address = receipt.contractAddress;
    if (!address) throw new Error(`${name}: no contract address in receipt`);
    const runtimeHash = keccak256(await provider.getCode(address));
    if (runtimeHash !== candidate.expectedRuntimeHash) {
      throw new Error(`${name}: deployed runtime ${runtimeHash} differs from reviewed ${candidate.expectedRuntimeHash}`);
    }
    results[name] = {
      address: getAddress(address),
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      effectiveGasPrice: receipt.gasPrice?.toString() ?? null,
      runtimeHash,
      runtimeMatchesReviewed: true,
      constructorArguments: reference.constructorArguments ?? [],
    };
    console.log(JSON.stringify({ name, address, block: receipt.blockNumber, gasUsed: receipt.gasUsed.toString(), runtimeHash }));
  }
  const summary = {
    change: 'base-crosschain-upgrade',
    chainId: 8453,
    deployedAtUtc: new Date().toISOString(),
    deployer,
    rpcHost: new URL(RPC).host,
    sourceBundle: path.relative(ROOT, BUNDLE),
    contracts: results,
  };
  fs.writeFileSync(OUT, JSON.stringify(summary, null, 2));
  console.log(JSON.stringify({ out: OUT, contracts: Object.fromEntries(Object.entries(results).map(([k, v]: any) => [k, v.address])) }));
  process.exit(0);
}

main().catch((error) => { console.error(error); process.exit(1); });
