import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID, dolomiteAddresses, dolomitePairs } from '../utils/constants';
import { verify } from '../utils/verify';

const deployDolomiteProvider: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log, get } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying DolomiteProvider...');

  // Get the existing ProviderManager address
  const providerManager = await get('ProviderManager');
  log(`Using ProviderManager at ${providerManager.address}`);

  // Deploy DolomiteProvider (no constructor arguments needed)
  const dolomiteProvider = await deploy('DolomiteProvider', {
    from: deployer,
    args: [], // No constructor arguments
    log: true,
  });

  log(`DolomiteProvider deployed at ${dolomiteProvider.address}`);

  // Verify contract on Arbitrum
  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(dolomiteProvider.address, []);
  }

  log('----------------------------------------------------');
  log('Setting up DolomiteProvider in ProviderManager...');

  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address
  );

  // Register DolomiteProvider in ProviderManager for USDC only
  // Note: Dolomite doesn't use yield tokens like Compound, but we need to register
  // the provider identifier for consistency with the system
  const usdcAsset = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831'; // USDC on Arbitrum
  
  // For Dolomite, we use the asset address as both asset and "yield token"
  // since Dolomite uses market IDs internally
  await providerManagerInstance.setYieldToken(
    'Dolomite_Provider',
    usdcAsset,
    usdcAsset // Using asset address as yield token for Dolomite
  );
  log(`Registered USDC (${usdcAsset}) for Dolomite_Provider`);

  log('----------------------------------------------------');
  log('DolomiteProvider deployment completed!');
  log(`DolomiteProvider address: ${dolomiteProvider.address}`);
  log(`ProviderManager address: ${providerManager.address}`);
  log('----------------------------------------------------');

  // Log Dolomite contract addresses for reference
  log('Dolomite Protocol addresses:');
  log(`  DolomiteMargin: ${dolomiteAddresses.margin}`);
  log(`  DolomiteGetter: ${dolomiteAddresses.getter}`);
  log(`  DepositWithdrawalProxy: ${dolomiteAddresses.proxy}`);
  log('----------------------------------------------------');
};

export default deployDolomiteProvider;
deployDolomiteProvider.tags = ['dolomite-provider'];
deployDolomiteProvider.dependencies = ['providers']; // Deploy after ProviderManager
