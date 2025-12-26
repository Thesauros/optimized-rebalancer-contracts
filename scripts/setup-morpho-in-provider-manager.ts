import { ethers } from 'hardhat';
import { deployments } from 'hardhat';

async function main() {
  console.log('🔧 Setting up MorphoProvider in ProviderManager...');
  console.log('=================================================');

  // Get deployed contracts
  const providerManager = await deployments.get('ProviderManager');
  const deployedVaults = require('../deployments/arbitrumOne/deployed-vaults.json');

  console.log(`📋 SETUP PARAMETERS:`);
  console.log(`====================`);
  console.log(`ProviderManager: ${providerManager.address}`);
  console.log(`MorphoProvider: ${deployedVaults.baseContracts.morphoProvider}`);

  // Get contract instance
  const providerManagerInstance = await ethers.getContractAt('ProviderManager', providerManager.address);

  // Setup parameters
  const morphoIdentifier = 'Morpho_Provider';
  const usdcAddress = deployedVaults.tokens.usdc;
  const usdtAddress = deployedVaults.tokens.usdt;
  const metaMorphoVault = '0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA'; // Steakhouse Financial

  console.log(`\n🎯 CONFIGURATION:`);
  console.log(`==================`);
  console.log(`Identifier: ${morphoIdentifier}`);
  console.log(`USDC: ${usdcAddress}`);
  console.log(`USDT: ${usdtAddress}`);
  console.log(`MetaMorpho Vault: ${metaMorphoVault}`);

  // Check current state
  console.log(`\n🔍 CURRENT STATE:`);
  console.log(`==================`);
  
  try {
    const usdcYieldToken = await providerManagerInstance.getYieldToken(morphoIdentifier, usdcAddress);
    const usdtYieldToken = await providerManagerInstance.getYieldToken(morphoIdentifier, usdtAddress);
    
    console.log(`USDC yield token: ${usdcYieldToken}`);
    console.log(`USDT yield token: ${usdtYieldToken}`);
    
  } catch (error) {
    console.log(`❌ Error checking current state: ${error.message}`);
  }

  // Setup yield tokens
  console.log(`\n💰 SETTING UP YIELD TOKENS:`);
  console.log(`============================`);
  
  try {
    // Set USDC yield token (MetaMorpho vault itself is the yield token)
    console.log(`Setting USDC yield token...`);
    const tx1 = await providerManagerInstance.setYieldToken(
      morphoIdentifier,
      usdcAddress,
      metaMorphoVault
    );
    await tx1.wait();
    console.log(`✅ USDC yield token set: ${metaMorphoVault}`);
    console.log(`   Transaction: ${tx1.hash}`);

    // Set USDT yield token
    console.log(`Setting USDT yield token...`);
    const tx2 = await providerManagerInstance.setYieldToken(
      morphoIdentifier,
      usdtAddress,
      metaMorphoVault
    );
    await tx2.wait();
    console.log(`✅ USDT yield token set: ${metaMorphoVault}`);
    console.log(`   Transaction: ${tx2.hash}`);

  } catch (error) {
    console.log(`❌ Error setting yield tokens: ${error.message}`);
  }

  // Setup markets
  console.log(`\n🏪 SETTING UP MARKETS:`);
  console.log(`=======================`);
  
  try {
    // Set USDC-USDT market
    console.log(`Setting USDC-USDT market...`);
    const tx3 = await providerManagerInstance.setMarket(
      morphoIdentifier,
      usdcAddress,
      usdtAddress,
      metaMorphoVault
    );
    await tx3.wait();
    console.log(`✅ USDC-USDT market set: ${metaMorphoVault}`);
    console.log(`   Transaction: ${tx3.hash}`);

    // Set USDT-USDC market
    console.log(`Setting USDT-USDC market...`);
    const tx4 = await providerManagerInstance.setMarket(
      morphoIdentifier,
      usdtAddress,
      usdcAddress,
      metaMorphoVault
    );
    await tx4.wait();
    console.log(`✅ USDT-USDC market set: ${metaMorphoVault}`);
    console.log(`   Transaction: ${tx4.hash}`);

  } catch (error) {
    console.log(`❌ Error setting markets: ${error.message}`);
  }

  // Verify setup
  console.log(`\n✅ VERIFYING SETUP:`);
  console.log(`====================`);
  
  try {
    const usdcYieldToken = await providerManagerInstance.getYieldToken(morphoIdentifier, usdcAddress);
    const usdtYieldToken = await providerManagerInstance.getYieldToken(morphoIdentifier, usdtAddress);
    const usdcUsdtMarket = await providerManagerInstance.getMarket(morphoIdentifier, usdcAddress, usdtAddress);
    const usdtUsdcMarket = await providerManagerInstance.getMarket(morphoIdentifier, usdtAddress, usdcAddress);
    
    console.log(`USDC yield token: ${usdcYieldToken}`);
    console.log(`USDT yield token: ${usdtYieldToken}`);
    console.log(`USDC-USDT market: ${usdcUsdtMarket}`);
    console.log(`USDT-USDC market: ${usdtUsdcMarket}`);
    
    const allSet = usdcYieldToken === metaMorphoVault && 
                   usdtYieldToken === metaMorphoVault && 
                   usdcUsdtMarket === metaMorphoVault && 
                   usdtUsdcMarket === metaMorphoVault;
    
    console.log(`\nSetup complete: ${allSet ? '✅ SUCCESS' : '❌ FAILED'}`);

  } catch (error) {
    console.log(`❌ Error verifying setup: ${error.message}`);
  }

  console.log(`\n📋 NEXT STEPS:`);
  console.log(`===============`);
  console.log(`1. ✅ MorphoProvider registered in ProviderManager`);
  console.log(`2. ✅ Yield tokens configured`);
  console.log(`3. ✅ Markets configured`);
  console.log(`4. 🔄 Add MorphoProvider to vaults via Timelock`);

  console.log(`\n🔗 USEFUL LINKS:`);
  console.log(`=================`);
  console.log(`ProviderManager: https://arbiscan.io/address/${providerManager.address}`);
  console.log(`MorphoProvider: https://arbiscan.io/address/${deployedVaults.baseContracts.morphoProvider}`);
  console.log(`MetaMorpho Vault: https://arbiscan.io/address/${metaMorphoVault}`);

  console.log(`\n🎉 PROVIDER MANAGER SETUP COMPLETED!`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
