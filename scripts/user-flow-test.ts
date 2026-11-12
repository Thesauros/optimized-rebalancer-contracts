import { ethers } from 'hardhat';
import * as fs from 'fs';

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const AMOUNT = 1_000_000n; // 1 USDC

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/base/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const usdc = await ethers.getContractAt('IERC20', USDC);

  console.log(
    'before: USDC =',
    (await usdc.balanceOf(user.address)).toString(),
    '| shares =',
    (await vault.balanceOf(user.address)).toString(),
  );

  const appTx = await usdc.approve(proxyAddr, AMOUNT);
  await appTx.wait();
  const depTx = await vault.deposit(AMOUNT, user.address);
  await depTx.wait();
  const sharesAfterDeposit = await vault.balanceOf(user.address);
  console.log('deposit 1 USDC ok, shares minted:', sharesAfterDeposit.toString());
  console.log(
    'vault: totalAssets =',
    (await vault.totalAssets()).toString(),
    '| totalSupply =',
    (await vault.totalSupply()).toString(),
  );

  const wTx = await vault.withdraw(AMOUNT, user.address, user.address);
  await wTx.wait();
  const dustShares = await vault.balanceOf(user.address);
  console.log('withdraw 1 USDC ok, dust shares left:', dustShares.toString());

  if (dustShares > 0n) {
    const rTx = await vault.redeem(dustShares, user.address, user.address);
    await rTx.wait();
    console.log('dust shares redeemed');
  }

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
  console.log('USER_FLOW_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
