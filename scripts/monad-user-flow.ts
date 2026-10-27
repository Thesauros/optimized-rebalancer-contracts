import { ethers } from 'hardhat';
import * as fs from 'fs';

const AMOUNT = 3_000_000n; // 3 USDC

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/monad/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const usdcAddr = fs.readFileSync('/tmp/monad-usdc.txt', 'utf8').trim();
  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const usdc = await ethers.getContractAt('IERC20', usdcAddr);

  console.log(
    'before: USDC =',
    (await usdc.balanceOf(user.address)).toString(),
    '| shares =',
    (await vault.balanceOf(user.address)).toString(),
  );

  const appTx = await usdc.approve(proxyAddr, AMOUNT, { gasLimit: 200_000n });
  await appTx.wait();

  const depTx = await vault.deposit(AMOUNT, user.address, {
    gasLimit: 1_500_000n,
  });
  const depRcpt = await depTx.wait();
  console.log('deposit 3 USDC ok, block', depRcpt ? depRcpt.blockNumber : 'n/a');
  const userShares = await vault.balanceOf(user.address);
  console.log('shares minted:', userShares.toString());
  console.log(
    'vault: totalAssets =',
    (await vault.totalAssets()).toString(),
    '| totalSupply =',
    (await vault.totalSupply()).toString(),
  );

  const sharesNeeded = await vault.previewWithdraw(AMOUNT);
  console.log('withdraw(3 USDC) needs shares:', sharesNeeded.toString());

  if (sharesNeeded <= userShares) {
    const wTx = await vault.withdraw(AMOUNT, user.address, user.address, {
      gasLimit: 2_500_000n,
    });
    const wRcpt = await wTx.wait();
    console.log('withdraw 3 USDC ok, block', wRcpt ? wRcpt.blockNumber : 'n/a');
  } else {
    console.log(
      'rounding edge: not enough shares for exact withdraw, redeeming full position instead',
    );
    const rTx = await vault.redeem(userShares, user.address, user.address, {
      gasLimit: 2_500_000n,
    });
    const rRcpt = await rTx.wait();
    console.log('redeem ok, block', rRcpt ? rRcpt.blockNumber : 'n/a');
  }

  const dustShares = await vault.balanceOf(user.address);
  if (dustShares > 0n) {
    const rTx = await vault.redeem(dustShares, user.address, user.address, {
      gasLimit: 2_500_000n,
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
  console.log('MONAD_USER_FLOW_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
