import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const [user] = await ethers.getSigners();
  const proxyAddr = JSON.parse(
    fs.readFileSync('deployments/base/USDCRebalancerProxy.json', 'utf8'),
  ).address;
  const vault = await ethers.getContractAt('Rebalancer', proxyAddr);
  const provider = ethers.provider;

  const block = await provider.getBlockNumber();
  console.log('block:', block);

  try {
    const res = await vault.withdraw.staticCall(1_000_000n, user.address, user.address);
    console.log('staticCall withdraw OK, shares:', res.toString());
  } catch (e: unknown) {
    console.log('staticCall withdraw FAILED:', e instanceof Error ? e.message.slice(0, 200) : e);
  }

  try {
    const res = await vault.redeem.staticCall(999_998n, user.address, user.address);
    console.log('staticCall redeem OK, assets:', res.toString());
  } catch (e: unknown) {
    console.log('staticCall redeem FAILED:', e instanceof Error ? e.message.slice(0, 200) : e);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
