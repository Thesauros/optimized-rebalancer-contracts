import { ethers } from 'hardhat';
import { deployments } from 'hardhat';

async function main() {
  console.log('🚀 Adding MorphoProvider to USDC vault via Timelock...');
  console.log('====================================================');

  const [deployer] = await ethers.getSigners();
  const { get } = deployments;

  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`🌐 Network: ${(await ethers.provider.getNetwork()).name}`);

  // Get deployed contracts info
  const deployedVaults = require('../deployments/arbitrumOne/deployed-vaults.json');
  
  const usdcVaultAddress = deployedVaults.vaults.usdc.address;
  const timelockAddress = deployedVaults.baseContracts.timelock;
  const morphoProviderAddress = deployedVaults.baseContracts.morphoProvider;

  console.log(`\n📋 CONTRACT ADDRESSES:`);
  console.log(`======================`);
  console.log(`USDC Vault: ${usdcVaultAddress}`);
  console.log(`Timelock: ${timelockAddress}`);
  console.log(`MorphoProvider: ${morphoProviderAddress}`);

  // Get contract instances
  const usdcVaultInstance = await ethers.getContractAt('IVault', usdcVaultAddress);
  const timelockInstance = await ethers.getContractAt('Timelock', timelockAddress);

  // Get current providers
  console.log(`\n🔍 GETTING CURRENT PROVIDERS:`);
  console.log(`==============================`);
  const currentProviders = await usdcVaultInstance.getProviders();
  console.log(`Current providers (${currentProviders.length}):`);
  currentProviders.forEach((provider, index) => {
    console.log(`  ${index + 1}. ${provider}`);
  });

  // Check if MorphoProvider is already added
  const isMorphoAlreadyAdded = currentProviders.some(
    provider => provider.toLowerCase() === morphoProviderAddress.toLowerCase()
  );

  if (isMorphoAlreadyAdded) {
    console.log(`\n⚠️  MorphoProvider is already added to USDC vault!`);
    return;
  }

  // Add MorphoProvider to the list
  const newProviders = [...currentProviders, morphoProviderAddress];
  
  console.log(`\n📊 NEW PROVIDERS LIST:`);
  console.log(`=======================`);
  console.log(`New providers (${newProviders.length}):`);
  newProviders.forEach((provider, index) => {
    console.log(`  ${index + 1}. ${provider}`);
  });

  // Encode the setProviders call
  console.log(`\n🔧 ENCODING TRANSACTION:`);
  console.log(`=========================`);
  const setProvidersInterface = new ethers.Interface([
    'function setProviders(address[] memory providers) external',
  ]);
  const callData = setProvidersInterface.encodeFunctionData('setProviders', [newProviders]);
  console.log(`Encoded call data: ${callData}`);

  // Get timelock delay and calculate execution time
  const delay = await timelockInstance.delay();
  const currentBlock = await ethers.provider.getBlock('latest');
  const currentBlockTime = currentBlock.timestamp;
  const executionTime = currentBlockTime + Number(delay.toString()) + 60; // Add 1 minute buffer

  console.log(`\n⏰ TIMING INFORMATION:`);
  console.log(`======================`);
  console.log(`Timelock delay: ${delay.toString()} seconds`);
  console.log(`Current block time: ${currentBlockTime}`);
  console.log(`Execution time: ${executionTime}`);
  console.log(`Execution date: ${new Date(executionTime * 1000).toISOString()}`);

  // Queue the transaction
  console.log(`\n📝 QUEUEING TRANSACTION:`);
  console.log(`=========================`);
  console.log(`Target: ${usdcVaultAddress}`);
  console.log(`Value: 0`);
  console.log(`Signature: setProviders(address[])`);
  console.log(`Data: ${callData}`);
  console.log(`Timestamp: ${executionTime}`);

  let queueTx;
  try {
    queueTx = await timelockInstance.queue(
      usdcVaultAddress,
      0,
      'setProviders(address[])',
      callData,
      executionTime
    );
    await queueTx.wait();
    
    console.log(`\n✅ TRANSACTION QUEUED SUCCESSFULLY!`);
    console.log(`===================================`);
    console.log(`Transaction hash: ${queueTx.hash}`);
    console.log(`Block number: ${queueTx.blockNumber}`);
    console.log(`Gas used: ${queueTx.gasLimit?.toString()}`);

    // Verify the transaction is queued
    const txId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'string', 'bytes', 'uint256'],
        [usdcVaultAddress, 0, 'setProviders(address[])', callData, executionTime]
      )
    );
    
    const isQueued = await timelockInstance.queued(txId);
    console.log(`Transaction ID: ${txId}`);
    console.log(`Is queued: ${isQueued ? '✅ YES' : '❌ NO'}`);

    console.log(`\n⏳ NEXT STEPS:`);
    console.log(`===============`);
    console.log(`1. Wait ${delay.toString()} seconds (until ${new Date(executionTime * 1000).toISOString()})`);
    console.log(`2. Execute the transaction using timelock.execute()`);
    console.log(`3. Use the same parameters as above`);

    console.log(`\n🔗 USEFUL LINKS:`);
    console.log(`=================`);
    console.log(`Timelock: https://arbiscan.io/address/${timelockAddress}`);
    console.log(`USDC Vault: https://arbiscan.io/address/${usdcVaultAddress}`);
    console.log(`Transaction: https://arbiscan.io/tx/${queueTx.hash}`);

  } catch (error) {
    console.error(`\n❌ ERROR QUEUEING TRANSACTION:`);
    console.error(`===============================`);
    console.error(`Error: ${error.message}`);
    
    if (error.data) {
      console.error(`Error data: ${error.data}`);
    }
    
    throw error;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Error:', error);
    process.exit(1);
  });