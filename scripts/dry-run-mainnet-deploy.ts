/**
 * Dry run of deploy/deploy-usdc-vault.ts against an Ethereum mainnet fork.
 *
 * Usage:
 *   FORK_RPC_URL=https://ethereum-rpc.publicnode.com \
 *     npx hardhat run scripts/dry-run-mainnet-deploy.ts --network hardhat
 *
 * Funds the local deployer with ETH and USDC on the fork, executes the exact
 * production deploy function, then smoke-tests the resulting vault. Writes
 * hardhat-deploy records to deployments/hardhat/, which is throwaway.
 */
import hre, { ethers } from 'hardhat';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';
import fs from 'fs';
import path from 'path';

import deployUsdcVault from '../deploy/deploy-usdc-vault';
import { chainConfigs } from '../utils/constants';

const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const USDC_HOLDER_API = `https://eth.blockscout.com/api/v2/tokens/${USDC}/holders`;

async function fundDeployer(assetAddress: string, deployer: string) {
  const asset = await ethers.getContractAt('IERC20', assetAddress);
  const metadata = await ethers.getContractAt('IERC20Metadata', assetAddress);
  const seed = ethers.parseUnits('1', await metadata.decimals());

  await hre.network.provider.send('hardhat_setBalance', [deployer, '0x8AC7230489E80000']); // 10 ETH

  const balance = await asset.balanceOf(deployer);
  if (balance >= seed * 10n) return;

  const res = await fetch(USDC_HOLDER_API);
  const json: any = await res.json();
  const holders: string[] = (json.items ?? [])
    .map((h: any) => h.address?.hash)
    .filter((a: any) => typeof a === 'string');

  for (const holder of holders) {
    if (holder.toLowerCase() === deployer.toLowerCase()) continue;
    const held = await asset.balanceOf(holder);
    if (held < seed * 10n) continue;

    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [holder],
    });
    await hre.network.provider.send('hardhat_setBalance', [holder, '0xDE0B6B3A7640000']);
    const signer = await ethers.getSigner(holder);
    await (await asset.connect(signer).transfer(deployer, seed * 10n)).wait();
    await hre.network.provider.request({
      method: 'hardhat_stopImpersonatingAccount',
      params: [holder],
    });
    console.log(`funded ${deployer} with 10 USDC from ${holder}`);
    return;
  }
  throw new Error('no USDC holder with a sufficient balance found to fund the dry run');
}

async function main() {
  const runtime: HardhatRuntimeEnvironment = hre;

  // same rule as the deploy script: a fork reports Hardhat's own chain id
  const chainId = process.env.FORK_CHAIN_ID
    ? BigInt(process.env.FORK_CHAIN_ID)
    : (await ethers.provider.getNetwork()).chainId;
  console.log(`forked chainId: ${chainId}`);
  if (chainId !== 1n) throw new Error(`this dry run is Ethereum-only, got chainId ${chainId}`);
  const chainConfig = chainConfigs[Number(chainId)];

  const [deployerSigner] = await ethers.getSigners();
  const deployer = deployerSigner.address;
  console.log(`dry-run deployer: ${deployer}`);

  await fundDeployer(chainConfig.asset, deployer);

  const ethBefore = await ethers.provider.getBalance(deployer);
  const started = Date.now();

  await deployUsdcVault(runtime);

  const ethAfter = await ethers.provider.getBalance(deployer);
  console.log('====================================================');
  console.log(`dry run finished in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  console.log(`deployer ETH spent: ${ethers.formatEther(ethBefore - ethAfter)}`);
  const factoryRecord = path.join(
    runtime.config.paths.deployments,
    runtime.network.name,
    'VaultFactory.json',
  );
  console.log(
    `proxy path: ${fs.existsSync(factoryRecord) ? 'atomic VaultFactory' : 'three-transaction pipeline'}`,
  );

  // post-deploy state (the record is written straight to disk by the deploy
  // script, so hardhat-deploy's in-memory registry does not know about it)
  const recordPath = path.join(
    runtime.config.paths.deployments,
    runtime.network.name,
    'USDCRebalancerProxy.json',
  );
  const proxy = { address: JSON.parse(fs.readFileSync(recordPath, 'utf8')).address as string };
  const vault = await ethers.getContractAt('Rebalancer', proxy.address);
  const [name, symbol, asset, totalAssets, totalSupply, entry, timelock, treasury] =
    await Promise.all([
      vault.name(),
      vault.symbol(),
      vault.asset(),
      vault.totalAssets(),
      vault.totalSupply(),
      vault.getEntryProvider(),
      vault.getTimelock(),
      vault.getTreasury(),
    ]);
  const providers = await vault.getProviders();
  console.log('----------------------------------------------------');
  console.log(`vault          : ${proxy.address}`);
  console.log(`name/symbol    : ${name} / ${symbol}`);
  console.log(`asset          : ${asset}`);
  console.log(`totalAssets    : ${totalAssets} (seed ${ethers.formatUnits(totalAssets, 6)})`);
  console.log(`totalSupply    : ${totalSupply} (dead shares held by the vault: ${await vault.balanceOf(proxy.address)})`);
  console.log(`entry provider : ${entry}`);
  console.log(`timelock       : ${timelock}`);
  console.log(`treasury       : ${treasury}`);
  console.log(`admin is treasury: ${await vault.hasRole(ethers.ZeroHash, treasury)}`);
  console.log(`providers (${providers.length}):`);
  for (const p of providers) {
    const id = await (await ethers.getContractAt('IProvider', p)).getIdentifier();
    const src = await (await ethers.getContractAt('IProvider', p)).getSource(asset, proxy.address, ethers.ZeroAddress);
    const bal = await (await ethers.getContractAt('IProvider', p)).getDepositBalance(proxy.address, proxy.address);
    const rate = await (await ethers.getContractAt('IProvider', p)).getDepositRate(proxy.address);
    console.log(`   ${p} ${id.padEnd(20)} source=${src} balance=${bal} rate=${rate}`);
  }

  // user-flow smoke test on the deployed vault
  console.log('----------------------------------------------------');
  const [, user] = await ethers.getSigners();
  const usdc = await ethers.getContractAt('IERC20', asset);
  const amount = ethers.parseUnits('1000', 6);

  const res = await fetch(USDC_HOLDER_API);
  const json: any = await res.json();
  let funded = false;
  for (const h of (json.items ?? []).map((i: any) => i.address?.hash)) {
    if (!h || h.toLowerCase() === user.address.toLowerCase()) continue;
    const held = await usdc.balanceOf(h);
    if (held < amount) continue;
    await runtime.network.provider.request({ method: 'hardhat_impersonateAccount', params: [h] });
    await runtime.network.provider.send('hardhat_setBalance', [h, '0xDE0B6B3A7640000']);
    const s = await ethers.getSigner(h);
    await (await usdc.connect(s).transfer(user.address, amount)).wait();
    await runtime.network.provider.request({ method: 'hardhat_stopImpersonatingAccount', params: [h] });
    funded = true;
    break;
  }
  if (!funded) throw new Error('could not fund the smoke-test user');

  const preview = await vault.previewDeposit(amount);
  await (await usdc.connect(user).approve(proxy.address, amount)).wait();
  const depTx = await vault.connect(user).deposit(amount, user.address);
  const depReceipt = await depTx.wait();
  const shares = await vault.balanceOf(user.address);
  console.log(`deposit 1000 USDC -> ${shares} shares (preview ${preview}), gas ${depReceipt?.gasUsed}`);

  const redeemTx = await vault.connect(user).redeem(shares, user.address, user.address);
  const redeemReceipt = await redeemTx.wait();
  const userBalance = await usdc.balanceOf(user.address);
  console.log(`redeem ${shares} shares -> ${userBalance} USDC back, gas ${redeemReceipt?.gasUsed}`);
  // provider balances round against the ERC-4626 supply, so a full redeem can
  // come back a unit short; anything beyond that is a real loss
  if (userBalance + 2n < amount) throw new Error('user lost more than rounding dust on a full redeem');
  console.log('SMOKE TEST OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
