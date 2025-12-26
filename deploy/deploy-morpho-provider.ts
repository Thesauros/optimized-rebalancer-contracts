import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID, morphoVaults } from '../utils/constants';
import { verify } from '../utils/verify';

const deployMorphoProvider: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log, get } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying MorphoProvider...');

  // Use Steakhouse Financial MetaMorpho vault for USDC
  const steakhouseVault = morphoVaults.find(
    (vault) => vault.strategy === 'Steakhouse Financial'
  );

  if (!steakhouseVault) {
    throw new Error('Steakhouse Financial MetaMorpho vault not found in constants.');
  }

  const metaMorphoVaultAddress = steakhouseVault.vaultAddress;

  log(`Using MetaMorpho vault: ${metaMorphoVaultAddress} (${steakhouseVault.strategy})`);

  // Deploy MorphoProvider with MetaMorpho vault address
  const morphoProvider = await deploy('MorphoProvider', {
    from: deployer,
    args: [metaMorphoVaultAddress],
    log: true,
  });

  log(`MorphoProvider deployed at ${morphoProvider.address}`);

  log('----------------------------------------------------');
  log('Setting up MorphoProvider in ProviderManager...');

  // Get the existing ProviderManager address
  const providerManager = await get('ProviderManager');
  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address
  );

  // Register MorphoProvider in ProviderManager
  // For Morpho, the MetaMorpho vault address is used as the yield token
  const usdcAsset = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831'; // USDC on Arbitrum

  await providerManagerInstance.setYieldToken(
    'Morpho_Provider',
    usdcAsset,
    metaMorphoVaultAddress // MetaMorpho vault is the yield token
  );
  log(`Registered USDC (${usdcAsset}) for Morpho_Provider with MetaMorpho vault ${metaMorphoVaultAddress}`);

  log('----------------------------------------------------');

  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(morphoProvider.address, [metaMorphoVaultAddress]);
  }

  log('MorphoProvider deployment completed!');
  log(`MorphoProvider address: ${morphoProvider.address}`);
  log(`ProviderManager address: ${providerManager.address}`);
  log('----------------------------------------------------');
};

export default deployMorphoProvider;
deployMorphoProvider.tags = ['morpho-provider'];
deployMorphoProvider.dependencies = ['providers']; // Deploy after ProviderManager

