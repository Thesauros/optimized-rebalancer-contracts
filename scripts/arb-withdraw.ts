import { ethers } from 'hardhat';
import * as fs from 'fs';

const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831';

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/arbitrum/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const usdc = await ethers.getContractAt('IERC20', ARB_USDC);

  const shares = await vault.balanceOf(user.address);
  const expectedAssets = await vault.previewRedeem(shares);
  console.log('redeeming shares:', shares.toString(), '-> ~', expectedAssets.toString(), 'USDC units');

  const rTx = await vault.redeem(shares, user.address, user.address, {
    gasLimit: 2_000_000n,
  });
  const rRcpt = await rTx.wait();
  console.log('redeem ok, block', rRcpt ? rRcpt.blockNumber : 'n/a', 'status', rRcpt ? rRcpt.status : 'n/a');

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
  console.log('ARB_WITHDRAW_OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
