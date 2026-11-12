import { ethers, network } from 'hardhat';
import * as fs from 'fs';

// CYCLE_ROUND=1|3 -> deposit 10 assets, CYCLE_ROUND=2 -> withdraw full position
const ROUND = process.env.CYCLE_ROUND ?? '1';

async function main() {
  const netName = network.name;
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync(`deployments/${netName}/USDCRebalancerProxy.json`, 'utf8'),
  ).address;

  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const assetAddr = await vault.asset();
  const token = new ethers.Contract(
    assetAddr,
    [
      'function balanceOf(address) view returns (uint256)',
      'function decimals() view returns (uint8)',
      'function symbol() view returns (string)',
      'function approve(address,uint256) returns (bool)',
      'function allowance(address,address) view returns (uint256)',
    ],
    user,
  );

  const decimals = Number(await token.decimals());
  const symbol = await token.symbol().catch(() => '???');
  const amt = 10n * 10n ** BigInt(decimals);
  const minAssets = await vault.getMinAssets();

  console.log(`[${netName}] round=${ROUND} vault=${proxyAddr} asset=${symbol} minAssets=${minAssets}`);
  console.log(
    `[${netName}] before: token=${await token.balanceOf(user.address)} shares=${await vault.balanceOf(user.address)} totalAssets=${await vault.totalAssets()}`,
  );

  if (ROUND === '2') {
    const shares = await vault.balanceOf(user.address);
    if (shares === 0n) {
      console.log(`[${netName}] NO_POSITION, nothing to withdraw`);
      return;
    }
    const expectAssets = await vault.previewRedeem(shares);
    const tx = await vault.redeem(shares, user.address, user.address, {
      gasLimit: 3_000_000n,
    });
    console.log(`[${netName}] redeem tx=${tx.hash}`);
    const rcpt = await tx.wait();
    if (rcpt?.status !== 1) throw new Error(`[${netName}] redeem FAILED`);
    console.log(
      `[${netName}] redeemed shares=${shares} (~assets ${expectAssets}), block=${rcpt.blockNumber}`,
    );
  } else {
    const bal = await token.balanceOf(user.address);
    if (bal < amt) throw new Error(`[${netName}] insufficient balance: ${bal} < ${amt}`);
    if (amt < minAssets) throw new Error(`[${netName}] below minAssets: ${amt} < ${minAssets}`);

    const allowance = await token.allowance(user.address, proxyAddr);
    if (allowance < amt) {
      const appTx = await token.approve(proxyAddr, amt, { gasLimit: 300_000n });
      console.log(`[${netName}] approve tx=${appTx.hash}`);
      const appRcpt = await appTx.wait();
      if (appRcpt?.status !== 1) throw new Error(`[${netName}] approve FAILED`);
    }

    const expectShares = await vault.previewDeposit(amt);
    const depTx = await vault.deposit(amt, user.address, { gasLimit: 2_500_000n });
    console.log(`[${netName}] deposit tx=${depTx.hash}`);
    const depRcpt = await depTx.wait();
    if (depRcpt?.status !== 1) throw new Error(`[${netName}] deposit FAILED`);
    console.log(
      `[${netName}] deposited ${amt} (~${expectShares} shares), block=${depRcpt.blockNumber}`,
    );
  }

  console.log(
    `[${netName}] after: token=${await token.balanceOf(user.address)} shares=${await vault.balanceOf(user.address)} totalAssets=${await vault.totalAssets()} totalSupply=${await vault.totalSupply()}`,
  );
  console.log(`[${netName}] ROUND_${ROUND}_OK`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
