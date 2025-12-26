import { ethers } from 'hardhat';
import { deployments } from 'hardhat';
import { tokenAddresses, morphoVaults } from '../utils/constants';

async function main() {
  console.log('🔧 Setting up MorphoProvider in ProviderManager...');
  console.log('=================================================');

  const [deployer] = await ethers.getSigners();
  const { get } = deployments;

  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`🌐 Network: ${(await ethers.provider.getNetwork()).name}`);

  // Get deployed contracts
  const providerManager = await get('ProviderManager');
  const morphoProvider = await get('MorphoProvider');

  console.log(`\n📋 CONTRACT ADDRESSES:`);
  console.log(`======================`);
  console.log(`ProviderManager: ${providerManager.address}`);
  console.log(`MorphoProvider: ${morphoProvider.address}`);

  // Get contract instances
  const providerManagerInstance = await ethers.getContractAt(
    'IProviderManager',
    providerManager.address
  );

  const morphoProviderInstance = await ethers.getContractAt(
    'IProvider',
    morphoProvider.address
  );

  // Get MorphoProvider identifier
  const identifier = await morphoProviderInstance.getIdentifier();
  console.log(`\n🏷️  PROVIDER IDENTIFIER: ${identifier}`);

  // Use Steakhouse Financial MetaMorpho vault
  const steakhouseVault = morphoVaults.find(
    (vault) => vault.strategy === 'Steakhouse Financial'
  );

  if (!steakhouseVault) {
    throw new Error('Steakhouse Financial MetaMorpho vault not found in constants.');
  }

  const metaMorphoVaultAddress = steakhouseVault.vaultAddress;

  console.log(`\n🎯 CONFIGURATION PARAMETERS:`);
  console.log(`=============================`);
  console.log(`Strategy: ${steakhouseVault.strategy}`);
  console.log(`MetaMorpho Vault: ${metaMorphoVaultAddress}`);
  console.log(`USDC Token: ${tokenAddresses.USDC}`);
  console.log(`USDT Token: ${tokenAddresses.USDT}`);

  console.log(`\n💰 SETTING UP YIELD TOKENS:`);
  console.log(`============================`);

  // Set yield token for USDC only
  // For Morpho, the MetaMorpho vault itself acts as the "yield token"
  const setYieldTokenUSDC = await providerManagerInstance.setYieldToken(
    identifier,
    tokenAddresses.USDC,
    metaMorphoVaultAddress
  );
  await setYieldTokenUSDC.wait();
  console.log(`✅ USDC yield token set: ${metaMorphoVaultAddress}`);
  console.log(`   Transaction: ${setYieldTokenUSDC.hash}`);

  console.log(`\n🏪 SETTING UP MARKETS:`);
  console.log(`=======================`);

  // Note: For MorphoProvider with only USDC, we don't need to set markets
  // Markets are only needed for asset pairs (e.g., USDC-USDT)
  // Since we only have USDC, there's no second asset to create a market pair
  console.log(`ℹ️  No markets to set - MorphoProvider only supports USDC`);
  console.log(`   Markets are only needed for asset pairs (e.g., USDC-USDT)`);

  console.log(`\n🔍 VERIFICATION:`);
  console.log(`=================`);

  // Verify yield token
  const usdcYieldToken = await providerManagerInstance.getYieldToken(
    identifier,
    tokenAddresses.USDC
  );

  console.log(`USDC yield token: ${usdcYieldToken}`);

  // Verify all are set correctly
  const allCorrect = 
    usdcYieldToken.toLowerCase() === metaMorphoVaultAddress.toLowerCase();

  console.log(`\n🎉 SETUP COMPLETE: ${allCorrect ? '✅ SUCCESS' : '❌ FAILED'}`);

  if (allCorrect) {
    console.log(`\n📝 SUMMARY:`);
    console.log(`============`);
    console.log(`✅ MorphoProvider configured in ProviderManager`);
    console.log(`✅ Yield token set for USDC`);
    console.log(`ℹ️  No markets needed (only single asset USDC)`);
    console.log(`✅ All using Steakhouse Financial MetaMorpho vault`);
    console.log(`\n🔗 LINKS:`);
    console.log(`==========`);
    console.log(`ProviderManager: https://arbiscan.io/address/${providerManager.address}`);
    console.log(`MorphoProvider: https://arbiscan.io/address/${morphoProvider.address}`);
    console.log(`MetaMorpho Vault: https://arbiscan.io/address/${metaMorphoVaultAddress}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Error:', error);
    process.exit(1);
  });
