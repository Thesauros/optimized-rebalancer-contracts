import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  tokenAddresses,
  WITHDRAW_FEE_PERCENT,
  OPERATOR_ROLE,
} from '../utils/constants';

const setupVaults: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  const { getNamedAccounts, deployments } = hre;
  const { deployer } = await getNamedAccounts();

  console.log('Setup Vaults Script');
  console.log('===================');
  console.log(`Deployer: ${deployer}`);

  // Get deployed vaults
  const [usdcVault, usdtVault] = await Promise.all([
    deployments.get('Rebalancer').catch(() => null), // USDC vault
    deployments.get('Rebalancer').catch(() => null), // USDT vault
  ]);

  // Check balances
  const usdcToken = await ethers.getContractAt('IERC20', tokenAddresses.USDC);
  const usdtToken = await ethers.getContractAt('IERC20', tokenAddresses.USDT);

  const usdcBalance = await usdcToken.balanceOf(deployer);
  const usdtBalance = await usdtToken.balanceOf(deployer);

  console.log(`USDC Balance: ${ethers.formatUnits(usdcBalance, 6)} USDC`);
  console.log(`USDT Balance: ${ethers.formatUnits(usdtBalance, 6)} USDT`);

  // Setup USDC Vault
  if (usdcVault && usdcBalance > 0) {
    console.log('\nSetting up USDC Vault...');
    const usdcVaultInstance = await ethers.getContractAt('Rebalancer', usdcVault.address);
    
    // Check if already setup
    const isSetup = await usdcVaultInstance.setupCompleted();
    if (!isSetup) {
      const setupAmount = ethers.parseUnits('1', 6); // 1 USDC
      if (usdcBalance >= setupAmount) {
        await usdcToken.approve(usdcVault.address, setupAmount);
        await usdcVaultInstance.setupVault(setupAmount);
        console.log(`  USDC Vault setup completed with ${ethers.formatUnits(setupAmount, 6)} USDC`);
      } else {
        console.log('  Insufficient USDC balance for setup');
      }
    } else {
      console.log('  USDC Vault already setup');
    }
  }

  // Setup USDT Vault
  if (usdtVault && usdtBalance > 0) {
    console.log('\nSetting up USDT Vault...');
    const usdtVaultInstance = await ethers.getContractAt('Rebalancer', usdtVault.address);
    
    // Check if already setup
    const isSetup = await usdtVaultInstance.setupCompleted();
    if (!isSetup) {
      const setupAmount = ethers.parseUnits('1', 6); // 1 USDT
      if (usdtBalance >= setupAmount) {
        await usdtToken.approve(usdtVault.address, setupAmount);
        await usdtVaultInstance.setupVault(setupAmount);
        console.log(`  USDT Vault setup completed with ${ethers.formatUnits(setupAmount, 6)} USDT`);
      } else {
        console.log('  Insufficient USDT balance for setup');
      }
    } else {
      console.log('  USDT Vault already setup');
    }
  }

  console.log('\nSetup completed!');
};

export default setupVaults;
setupVaults.tags = ['setup-vaults'];
