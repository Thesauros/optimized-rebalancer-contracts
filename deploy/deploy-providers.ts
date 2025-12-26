import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID, cometPairs } from '../utils/constants';
import { verify } from '../utils/verify';

const deployProviders: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const providersToDeploy = ['AaveV3Provider', 'CompoundV3Provider'];

  log('----------------------------------------------------');
  log('Deploying ProviderManager...');

  const providerManager = await deploy('ProviderManager', {
    from: deployer,
    args: [deployer],
    log: true,
  });

  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(providerManager.address, [deployer]);
  }

  log(`ProviderManager at ${providerManager.address}`);

  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address
  );

  log('----------------------------------------------------');
  log('Setting up yield tokens...');

  // Register CompoundV3Provider yield tokens
  for (const { asset, cToken } of cometPairs) {
    await providerManagerInstance.setYieldToken(
      'Compound_V3_Provider',
      asset,
      cToken
    );
  }

  // Register AaveV3Provider yield tokens
  log('Setting up AaveV3Provider yield tokens...');
  const AAVE_POOL_ADDRESSES_PROVIDER = '0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb';
  const aavePoolAddressesProvider = await ethers.getContractAt(
    'IPoolAddressesProvider',
    AAVE_POOL_ADDRESSES_PROVIDER
  );
  const aavePoolAddress = await aavePoolAddressesProvider.getPool();
  const aavePool = await ethers.getContractAt('IPool', aavePoolAddress);

  // Register USDC and USDT for AaveV3Provider
  const aaveAssets = [
    { name: 'USDC', address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831' },
    { name: 'USDT', address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9' },
  ];

  for (const asset of aaveAssets) {
    const reserveData = await aavePool.getReserveData(asset.address);
    await providerManagerInstance.setYieldToken(
      'Aave_V3_Provider',
      asset.address,
      reserveData.aTokenAddress
    );
    log(`Registered ${asset.name} (${asset.address}) → aToken: ${reserveData.aTokenAddress}`);
  }

  log('----------------------------------------------------');
  log('Deploying all the providers...');

  for (const providerName of providersToDeploy) {
    const args =
      providerName === 'CompoundV3Provider' ? [providerManager.address] : [];

    const provider = await deploy(providerName, {
      from: deployer,
      args: args,
      log: true,
    });

    log(`${providerName} deployed at ${provider.address}`);
    log('----------------------------------------------------');

    if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
      await verify(provider.address, args);
    }
  }
};

export default deployProviders;
deployProviders.tags = ['all', 'providers'];
