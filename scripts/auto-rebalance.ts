import { ethers } from 'hardhat';
import { ConfigLoader } from '../utils/config';

interface RebalanceOpportunity {
  vault: string;
  vaultName: string;
  currentProvider: string;
  bestProvider: string;
  apyDifference: number;
  estimatedProfit: string;
  gasEstimate: bigint;
}

interface ProviderAPY {
  name: string;
  address: string;
  apy: number;
}

async function main() {
  console.log('Thesauros Auto-Rebalancing Bot');
  console.log('==================================\n');

  // Check if we have a private key
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.log('Error: PRIVATE_KEY environment variable not set');
    console.log('Please set your private key in .env file');
    process.exit(1);
  }

  // Load configuration
  const configLoader = new ConfigLoader();
  const config = configLoader.loadConfig();
  
  if (!config) {
    console.error('Failed to load configuration');
    return;
  }

  // Contract addresses from config
  const vaultAddresses = Object.fromEntries(
    Object.entries(config.vaults).map(([token, vault]) => [
      `${token} Vault`, 
      vault.address
    ])
  );

  const providerAddresses = Object.fromEntries(
    Object.entries(config.baseContracts)
      .filter(([name]) => name.includes('Provider'))
      .map(([name, contract]) => [name, contract.address])
  );

  const vaultManagerAddress = config.baseContracts.VaultManager.address;

  // Minimum APY difference for rebalancing (in percentage)
  const MIN_APY_DIFFERENCE = 0.5; // 0.5%
  
  // Minimum amount for rebalancing
  const MIN_REBALANCE_AMOUNT = ethers.parseUnits('100', 6); // 100 USDC

  console.log('Analyzing rebalancing opportunities...\n');

  const opportunities: RebalanceOpportunity[] = [];

  // Get current gas prices
  const gasPrice = await ethers.provider.getFeeData();
  const currentGasPrice = gasPrice.gasPrice || ethers.parseUnits('0.1', 'gwei');

  console.log(`Current gas price: ${ethers.formatUnits(currentGasPrice, 'gwei')} gwei`);

  // Analyze each vault
  for (const [vaultName, vaultAddress] of Object.entries(vaultAddresses)) {
    try {
      console.log(`\nAnalyzing ${vaultName}...`);
      
      const vault = await ethers.getContractAt('Rebalancer', vaultAddress);
      const activeProvider = await vault.activeProvider();
      const totalAssets = await vault.totalAssets();
      
      // Get APY for all providers
      const providerAPYs: ProviderAPY[] = [];
      
      for (const [providerName, providerAddress] of Object.entries(providerAddresses)) {
        try {
          const apy = await getProviderAPY(providerAddress, vaultAddress);
          providerAPYs.push({
            name: providerName,
            address: providerAddress,
            apy: apy
          });
          
          console.log(`   ${providerName}: ${apy.toFixed(4)}% APY`);
        } catch (error) {
          console.log(`   Error getting APY for ${providerName}: ${error}`);
        }
      }

      if (providerAPYs.length < 2) {
        console.log(`   Skipping ${vaultName} - insufficient provider data`);
        continue;
      }

      // Find the best provider
      const sortedProviders = providerAPYs.sort((a, b) => b.apy - a.apy);
      const bestProvider = sortedProviders[0];
      const currentProviderAPY = providerAPYs.find(p => p.address === activeProvider);
      
      if (!currentProviderAPY) {
        console.log(`   Current provider not found in APY data`);
        continue;
      }

      console.log(`   Current Provider: ${currentProviderAPY.name} (${currentProviderAPY.apy.toFixed(4)}%)`);
      console.log(`   Best Provider: ${bestProvider.name} (${bestProvider.apy.toFixed(4)}%)`);

      const apyDifference = bestProvider.apy - currentProviderAPY.apy;
      console.log(`   APY Difference: ${apyDifference.toFixed(4)}%`);

      if (apyDifference > MIN_APY_DIFFERENCE) {
        // Calculate potential profit
        const annualProfit = (totalAssets * BigInt(Math.floor(apyDifference * 100))) / BigInt(10000);
        const dailyProfit = annualProfit / BigInt(365);
        
        // Estimate gas cost for rebalancing
        const gasEstimate = await estimateRebalanceGas(vaultAddress, bestProvider.address);
        const gasCost = gasEstimate * currentGasPrice;
        
        const estimatedProfit = ethers.formatUnits(dailyProfit, 18);
        const gasCostFormatted = ethers.formatEther(gasCost);
        
        console.log(`   Estimated Daily Profit: ${estimatedProfit} tokens`);
        console.log(`   Estimated Gas Cost: ${gasCostFormatted} ETH`);
        
        if (dailyProfit > gasCost) {
          opportunities.push({
            vault: vaultAddress,
            vaultName: vaultName,
            currentProvider: currentProviderAPY.name,
            bestProvider: bestProvider.name,
            apyDifference: apyDifference,
            estimatedProfit: estimatedProfit,
            gasEstimate: gasEstimate
          });
          
          console.log(`   PROFITABLE REBALANCING OPPORTUNITY FOUND!`);
        } else {
          console.log(`   Not profitable - gas cost exceeds daily profit`);
        }
      } else {
        console.log(`   APY difference too small for rebalancing`);
      }
      
    } catch (error) {
      console.log(`   Error analyzing ${vaultName}: ${error}`);
    }
  }

  console.log('\nRebalancing Opportunities Found:');
  console.log('===================================\n');

  if (opportunities.length === 0) {
    console.log('No profitable rebalancing opportunities found');
    return;
  }

  // Sort opportunities by profit potential
  opportunities.sort((a, b) => parseFloat(b.estimatedProfit) - parseFloat(a.estimatedProfit));

  for (const opportunity of opportunities) {
    console.log(`Vault: ${opportunity.vaultName}`);
    console.log(`   Current Provider: ${opportunity.currentProvider}`);
    console.log(`   Best Provider: ${opportunity.bestProvider}`);
    console.log(`   APY Difference: ${opportunity.apyDifference.toFixed(4)}%`);
    console.log(`   Estimated Daily Profit: ${opportunity.estimatedProfit} tokens`);
    console.log(`   Gas Estimate: ${opportunity.gasEstimate.toString()} gas`);
    console.log('');
  }

  // Ask user if they want to execute rebalancing
  console.log('Would you like to execute rebalancing? (y/n)');
  
  // In a real implementation, you would wait for user input
  // For now, we'll just show the opportunities
  console.log('Automatic execution disabled for safety');
}

async function getProviderAPY(providerAddress: string, vaultAddress: string): Promise<number> {
  // This is a simplified APY calculation
  // In a real implementation, you would fetch actual APY from the provider
  const baseAPY = 3.5;
  const randomFactor = Math.random() * 2 - 1;
  return Math.max(0, baseAPY + randomFactor);
}

async function estimateRebalanceGas(vaultAddress: string, newProviderAddress: string): Promise<bigint> {
  // This is a simplified gas estimation
  // In a real implementation, you would estimate actual gas usage
  return BigInt(200000); // 200k gas estimate
}

main().catch((error) => {
  console.error('Error in auto-rebalancing:', error);
  process.exit(1);
});
