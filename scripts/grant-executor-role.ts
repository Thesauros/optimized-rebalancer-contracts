/**
 * Grant EXECUTOR_ROLE to the rebalancer EOA on the vault proxies.
 *
 * Usage:
 *   npx hardhat run scripts/grant-executor-role.ts                # read-only recon
 *   GRANT=1 npx hardhat run scripts/grant-executor-role.ts        # actually grant
 *
 * Only the vault ADMIN_ROLE holder can grant. The admin is the address
 * passed as admin_ at initialize (TREASURY_ADDRESS at deploy time).
 */
import 'dotenv/config';
import { ethers } from 'ethers';

const ADMIN_ROLE = ethers.ZeroHash;
const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');
const TARGET = '0x48aee620254556dfa676d9ceb0B2f2a19B6469c5';
const TREASURY = process.env.TREASURY_ADDRESS!;

const VAULT_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function grantRole(bytes32 role, address account)',
];

const NETWORKS: {
  name: string;
  chainId: number;
  url: string;
  vault: string;
}[] = [
  {
    name: 'base',
    chainId: 8453,
    url:
      process.env.BASE_RPC_URL ??
      `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_PROJECT_ID}`,
    vault: '0x3C7739173cca612B6394EE57131458185A5beC44',
  },
  {
    name: 'arbitrum',
    chainId: 42161,
    url:
      process.env.ARBITRUM_RPC_URL &&
      !process.env.ARBITRUM_RPC_URL.includes('alchemy.com')
        ? process.env.ARBITRUM_RPC_URL
        : 'https://arb1.arbitrum.io/rpc',
    vault: '0x4E5c0A4C11d713002D74bA43a458efc31bc76378',
  },
  {
    name: 'plasma',
    chainId: 9745,
    url: process.env.PLASMA_RPC_URL ?? 'https://rpc.plasma.to',
    vault: '0x2Ed9B7fB6Bbe0920145B2a79c18C3f7cFCAE3C99',
  },
  {
    name: 'monad',
    chainId: 143,
    url: process.env.MONAD_RPC_URL ?? 'https://rpc.monad.xyz',
    vault: '0x40F1fBf6a92155a6D321c09936234BFEb9Ec4760',
  },
  {
    name: 'mainnet',
    chainId: 1,
    url: process.env.ETHEREUM_RPC_URL ?? 'https://ethereum-rpc.publicnode.com',
    vault: '0xc3156Da39EeEa9De80F1d74b497C0E4A7030Aae3',
  },
];

async function main() {
  if (!process.env.DEPLOYER_PRIVATE_KEY) {
    throw new Error('DEPLOYER_PRIVATE_KEY not set');
  }
  const walletPk = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY);
  const deployer = walletPk.address;
  const grant = process.env.GRANT === '1';

  console.log(`deployer (signer): ${deployer}`);
  console.log(`treasury (env):    ${TREASURY}`);
  console.log(`target executor:   ${TARGET}`);
  console.log(`EXECUTOR_ROLE id:  ${EXECUTOR_ROLE}`);
  console.log(`mode: ${grant ? 'GRANT' : 'recon only'}`);
  console.log('');

  for (const net of NETWORKS) {
    console.log(`=== ${net.name} (chainId ${net.chainId}) ===`);
    try {
      const provider = new ethers.JsonRpcProvider(net.url, net.chainId);
      const code = await provider.getCode(net.vault);
      if (code === '0x') {
        console.log(`  !! no code at vault ${net.vault} — wrong address?`);
        continue;
      }
      const vault = new ethers.Contract(net.vault, VAULT_ABI, provider);
      const [name, symbol, treasuryIsAdmin, deployerIsAdmin, targetHasExec] =
        await Promise.all([
          vault.name(),
          vault.symbol(),
          vault.hasRole(ADMIN_ROLE, TREASURY),
          vault.hasRole(ADMIN_ROLE, deployer),
          vault.hasRole(EXECUTOR_ROLE, TARGET),
        ]);
      console.log(`  vault ${net.vault} (${name} / ${symbol})`);
      console.log(`  treasury has ADMIN_ROLE:  ${treasuryIsAdmin}`);
      console.log(`  deployer has ADMIN_ROLE:  ${deployerIsAdmin}`);
      console.log(`  target has EXECUTOR_ROLE: ${targetHasExec}`);

      if (grant && !targetHasExec) {
        if (!deployerIsAdmin) {
          console.log(
            '  -- deployer is NOT admin on this vault, cannot grant from this key',
          );
          continue;
        }
        const signer = walletPk.connect(provider);
        const vaultW = vault.connect(signer) as ethers.Contract;
        const tx = await vaultW.grantRole(EXECUTOR_ROLE, TARGET);
        console.log(`  grantRole tx sent: ${tx.hash}`);
        const rcpt = await tx.wait(2);
        console.log(
          `  confirmed in block ${rcpt.blockNumber}, status ${rcpt.status}`,
        );
        const ok = await vault.hasRole(EXECUTOR_ROLE, TARGET);
        console.log(`  post-check target has EXECUTOR_ROLE: ${ok}`);
      }
    } catch (e) {
      console.log(`  !! error: ${(e as Error).message}`);
    }
    console.log('');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
