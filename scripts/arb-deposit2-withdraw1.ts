import { ethers } from 'hardhat';
import * as fs from 'fs';

const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831';
const DEPOSIT_AMOUNT = 2_000_000n; // 2 USDC
const WITHDRAW_AMOUNT = 1_000_000n; // 1 USDC

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/arbitrum/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const usdc = await ethers.getContractAt('IERC20', ARB_USDC);

  console.log(
    'before: USDC =',
    (await usdc.balanceOf(user.address)).toString(),
    '| shares =',
    (await vault.balanceOf(user.address)).toString(),
  );

  const appTx = await usdc.approve(proxyAddr, DEPOSIT_AMOUNT, {
    gasLimit: 200_000n,
  });
  await appTx.wait();

  const depTx = await vault.deposit(DEPOSIT_AMOUNT, user.address, {
    gasLimit: 1_000_000n,
  });
  const depRcpt = await depTx.wait();
  console.log('deposit 2 USDC ok, block', depRcpt ? depRcpt.blockNumber : 'n/a');
  console.log('shares now:', (await vault.balanceOf(user.address)).toString());

  const sharesNeeded = await vault.previewWithdraw(WITHDRAW_AMOUNT);
  console.log('withdraw(1 USDC) needs shares:', sharesNeeded.toString());

  const wTx = await vault.withdraw(
    WITHDRAW_AMOUNT,
    user.address,
    user.address,
    { gasLimit: 2_000_000n },
  );
  const wRcpt = await wTx.wait();
  console.log('withdraw 1 USDC ok, block', wRcpt ? wRcpt.blockNumber : 'n/a');

  console.log(
    'after: USDC =',
    (await usdc.balanceOf(user.address)).toString(),
    '| shares =',
    (await vault.balanceOf(user.address)).toString(),
  );
  console.log(
    'vault: totalAssets =',
    (await vault.totalAssets()).toString(),
    '| totalSupply =',
    (await vault.totalSupply()).toString(),
  );
  console.log('ARB_DEPOSIT2_WITHDRAW1_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
