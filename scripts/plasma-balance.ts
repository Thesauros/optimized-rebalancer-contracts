import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const [user] = await ethers.getSigners();
  const constantsSrc = fs.readFileSync('utils/constants.ts', 'utf8');
  const m = constantsSrc.match(/9745:\s*\{\s*asset:\s*'([^']+)'/);
  const usdt0Addr = m![1];
  const usdt0 = await ethers.getContractAt('IERC20', usdt0Addr);
  console.log('USDT0 balance on Plasma:', (await usdt0.balanceOf(user.address)).toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
