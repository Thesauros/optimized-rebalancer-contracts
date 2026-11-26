import { ethers } from 'hardhat';
import * as fs from 'fs';

const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831';
const AMOUNT = 1_000_000n; // 1 USDC

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

  const appTx = await usdc.approve(proxyAddr, AMOUNT, { gasLimit: 200_000n });
  await appTx.wait();

  const depTx = await vault.deposit(AMOUNT, user.address, {
    gasLimit: 1_000_000n,
  });
  const depRcpt = await depTx.wait();
  console.log('deposit 1 USDC ok, block', depRcpt ? depRcpt.blockNumber : 'n/a');
  console.log(
    'shares minted:',
    (await vault.balanceOf(user.address)).toString(),
  );
  console.log(
    'vault: totalAssets =',
    (await vault.totalAssets()).toString(),
    '| totalSupply =',
    (await vault.totalSupply()).toString(),
  );

  const wTx = await vault.withdraw(AMOUNT, user.address, user.address, {
    gasLimit: 2_000_000n,
  });
  const wRcpt = await wTx.wait();
  console.log('withdraw 1 USDC ok, block', wRcpt ? wRcpt.blockNumber : 'n/a');

  const dustShares = await vault.balanceOf(user.address);
  console.log('dust shares left:', dustShares.toString());
  if (dustShares > 0n) {
    const rTx = await vault.redeem(dustShares, user.address, user.address, {
      gasLimit: 2_000_000n,
    });
    const rRcpt = await rTx.wait();
    console.log('dust redeemed, block', rRcpt ? rRcpt.blockNumber : 'n/a');
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
  console.log('ARB_USER_FLOW_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
