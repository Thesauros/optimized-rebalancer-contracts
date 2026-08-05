import * as dotenv from 'dotenv';
import { Wallet, JsonRpcProvider, formatEther, Contract, formatUnits } from 'ethers';

dotenv.config();

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

async function main() {
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key) {
    console.log('DEPLOYER_PRIVATE_KEY: MISSING');
    process.exit(1);
  }

  const wallet = new Wallet(key);
  console.log('DEPLOYER_ADDRESS:', wallet.address);
  console.log('TREASURY_ADDRESS:', process.env.TREASURY_ADDRESS || 'MISSING');
  console.log('MANAGEMENT_FEE_PERCENT:', process.env.MANAGEMENT_FEE_PERCENT || '0 (default)');
  console.log('PERFORMANCE_FEE_PERCENT:', process.env.PERFORMANCE_FEE_PERCENT || '0 (default)');
  console.log('TIMELOCK_DELAY:', process.env.TIMELOCK_DELAY || '1800 (default)');
  console.log('ALCHEMY_PROJECT_ID set:', !!process.env.ALCHEMY_PROJECT_ID);
  console.log('ETHERSCAN_API_KEY set:', !!process.env.ETHERSCAN_API_KEY);

  const provider = new JsonRpcProvider('https://mainnet.base.org');
  const usdc = new Contract(USDC, ['function balanceOf(address) view returns (uint256)'], provider);
  const [balance, usdcBalance, feeData, network] = await Promise.all([
    provider.getBalance(wallet.address),
    usdc.balanceOf(wallet.address),
    provider.getFeeData(),
    provider.getNetwork(),
  ]);
  console.log('Network chainId:', network.chainId.toString());
  console.log('ETH balance:', formatEther(balance));
  console.log('USDC balance:', formatUnits(usdcBalance, 6));
  console.log('Current base fee (gwei):', feeData.gasPrice ? (Number(feeData.gasPrice) / 1e9).toFixed(6) : 'n/a');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
