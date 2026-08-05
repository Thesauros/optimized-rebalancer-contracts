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

  const wTx = await vault.withdraw(AMOUNT, user.address, user.address, {
    gasLimit: 2_000_000n,
  });
  const wRcpt = await wTx.wait();
  console.log('withdraw 1 USDC ok, tx mined in block', wRcpt ? wRcpt.blockNumber : 'n/a');

  const remaining = await vault.balanceOf(user.address);
  console.log('shares remaining after withdraw:', remaining.toString());

  if (remaining > 0n) {
    const rTx = await vault.redeem(remaining, user.address, user.address, {
      gasLimit: 2_000_000n,
    });
    const rRcpt = await rTx.wait();
    console.log('redeem of remainder ok, block', rRcpt ? rRcpt.blockNumber : 'n/a');
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
  console.log('WITHDRAW_FLOW_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
