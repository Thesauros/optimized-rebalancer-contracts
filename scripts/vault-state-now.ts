import { ethers } from 'hardhat';
import * as fs from 'fs';

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const COMET = '0xb125E6687d4313864e53df431d5425969c15Eb2F';

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/base/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const erc20 = ['function balanceOf(address) view returns (uint256)'];
  const vaultAbi = [
    ...erc20,
    'function totalSupply() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function getLastTotalAssets() view returns (uint256)',
    'function getLastTimestamp() view returns (uint64)',
    'function getManagementFee() view returns (uint96)',
    'function getPerformanceFee() view returns (uint96)',
    'function previewWithdraw(uint256) view returns (uint256)',
    'function previewRedeem(uint256) view returns (uint256)',
  ];
  const vault = new ethers.Contract(proxyAddr, vaultAbi, ethers.provider);
  const usdc = new ethers.Contract(USDC, erc20, ethers.provider);
  const comet = new ethers.Contract(COMET, erc20, ethers.provider);

  console.log('user USDC:', (await usdc.balanceOf(user.address)).toString());
  console.log('user shares:', (await vault.balanceOf(user.address)).toString());
  console.log('vault USDC (idle):', (await usdc.balanceOf(proxyAddr)).toString());
  console.log('vault comet balance:', (await comet.balanceOf(proxyAddr)).toString());
  console.log('totalSupply:', (await vault.totalSupply()).toString());
  console.log('totalAssets:', (await vault.totalAssets()).toString());
  console.log('lastTotalAssets:', (await vault.getLastTotalAssets()).toString());
  console.log('mgmtFee:', (await vault.getManagementFee()).toString());
  console.log('perfFee:', (await vault.getPerformanceFee()).toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
