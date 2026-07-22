import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  BASE_CHAIN_ID,
  TREASURY_ADDRESS,
  MANAGEMENT_FEE_PERCENT,
  PERFORMANCE_FEE_PERCENT,
  TIMELOCK_DELAY,
  tokenAddresses,
  cometPairs,
  morphoVaults,
} from '../utils/constants';
import { verify } from '../utils/verify';

const deployUsdcVault: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const chainId = (await ethers.provider.getNetwork()).chainId;
  const waitConfirmations = chainId === BASE_CHAIN_ID ? 2 : 0;

  const name = 'Thesauros USDC Vault';
  const symbol = 'tUSDC';

  const usdcAddress = tokenAddresses.USDC;

  const minAssets = ethers.parseUnits('1', 6); // Be sure that you have the balance available in the deployer account

  const providers: string[] = [];

  /*//////////////////////////////////////////////////////////////
                            DEPLOY PROVIDERS
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying ProviderManager...');

  const providerManager = await deploy('ProviderManager', {
    from: deployer,
    args: [deployer],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`ProviderManager at ${providerManager.address}`);

  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address,
  );

  log('----------------------------------------------------');
  log('Setting up yield tokens...');

  for (const { asset, cToken } of cometPairs) {
    await providerManagerInstance
      .setYieldToken('Compound_V3_Provider', asset, cToken)
      .then((tx) => tx.wait());
  }

  if (chainId === BASE_CHAIN_ID) {
    await verify(providerManager.address, [deployer]);
  }

  log('----------------------------------------------------');
  log('Deploying AaveV3 and CompoundV3 providers...');

  const providersToDeploy = ['CompoundV3Provider', 'AaveV3Provider'];

  for (const providerName of providersToDeploy) {
    const args =
      providerName === 'CompoundV3Provider' ? [providerManager.address] : [];

    const provider = await deploy(providerName, {
      from: deployer,
      args: args,
      log: true,
      waitConfirmations: waitConfirmations,
    });

    log('----------------------------------------------------');
    log(`${providerName} at ${provider.address}`);

    providers.push(provider.address);

    if (chainId === BASE_CHAIN_ID) {
      await verify(provider.address, args);
    }
  }

  log('----------------------------------------------------');
  log('Deploying Morpho providers...');

  for (const { strategy, vaultAddress } of morphoVaults) {
    const deploymentName = `${strategy}MorphoProvider`;
    const provider = await deploy(deploymentName, {
      contract: 'MorphoProvider',
      from: deployer,
      args: [vaultAddress],
      log: true,
      waitConfirmations: waitConfirmations,
    });

    log('----------------------------------------------------');
    log(`MorphoProvider for ${strategy} strategy at ${provider.address}`);

    providers.push(provider.address);

    if (chainId === BASE_CHAIN_ID) {
      await verify(provider.address, [vaultAddress]);
    }
  }

  /*//////////////////////////////////////////////////////////////
                            DEPLOY TIMELOCK
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying Timelock...');

  const timelock = await deploy('Timelock', {
    from: deployer,
    args: [deployer, TIMELOCK_DELAY],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`Timelock at ${timelock.address}`);

  if (chainId === BASE_CHAIN_ID) {
    await verify(timelock.address, [deployer, TIMELOCK_DELAY]);
  }

  /*//////////////////////////////////////////////////////////////
                         DEPLOY USDC REBALANCER
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying USDC Rebalancer...');

  const implementation = await deploy('USDCRebalancerImplementation', {
    contract: 'Rebalancer',
    from: deployer,
    args: [],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`Implementation at ${implementation.address}`);

  const proxy = await deploy('USDCRebalancerProxy', {
    contract: 'TransparentUpgradeableProxy',
    from: deployer,
    args: [implementation.address, TREASURY_ADDRESS, '0x'],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`Proxy at ${proxy.address}`);

  const usdcInstance = await ethers.getContractAt('IERC20', usdcAddress);
  await usdcInstance.approve(proxy.address, minAssets).then((tx) => tx.wait());

  const usdcRebalancerInstance = await ethers.getContractAt(
    'Rebalancer',
    proxy.address,
  );

  await usdcRebalancerInstance
    .initialize(
      TREASURY_ADDRESS!,
      timelock.address,
      usdcAddress,
      name,
      symbol,
      providers,
      TREASURY_ADDRESS!,
      MANAGEMENT_FEE_PERCENT,
      PERFORMANCE_FEE_PERCENT,
      minAssets,
    )
    .then((tx) => tx.wait());

  if (chainId === BASE_CHAIN_ID) {
    await verify(implementation.address, []);
    await verify(proxy.address, [
      implementation.address,
      TREASURY_ADDRESS,
      '0x',
    ]);
  }
};

export default deployUsdcVault;
deployUsdcVault.tags = ['all', 'usdc-vault'];
