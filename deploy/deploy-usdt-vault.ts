import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  ARBITRUM_CHAIN_ID,
  TREASURY_ADDRESS,
  WITHDRAW_FEE_PERCENT,
  OPERATOR_ROLE,
  tokenAddresses,
  morphoVaults,
} from '../utils/constants';
import { verify } from '../utils/verify';

const deployUsdtVault: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const name = 'Thesauros USDT Vault';
  const symbol = 'tUSDT';

  const usdtAddress = tokenAddresses.USDT;

  const initialDeposit = ethers.parseUnits('1', 6); // Be sure that you have the balance available in the deployer account

  log('----------------------------------------------------');
  log('Setting up USDT yield tokens in ProviderManager...');

  const providerManager = await deployments.get('ProviderManager');
  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address
  );

  const usdtAsset = tokenAddresses.USDT;
  
  // Setup DolomiteProvider for USDT
  await providerManagerInstance.setYieldToken(
    'Dolomite_Provider',
    usdtAsset,
    usdtAsset // Using asset address as yield token for Dolomite
  );
  log(`Registered USDT (${usdtAsset}) for Dolomite_Provider`);

  // Setup MorphoProvider for USDT (using same MetaMorpho vault)
  const steakhouseVault = morphoVaults.find(
    (vault) => vault.strategy === 'Steakhouse Financial'
  );
  if (steakhouseVault) {
    await providerManagerInstance.setYieldToken(
      'Morpho_Provider',
      usdtAsset,
      steakhouseVault.vaultAddress
    );
    log(`Registered USDT (${usdtAsset}) for Morpho_Provider`);
  }

  log('----------------------------------------------------');
  log('Deploying USDT Rebalancer...');

  const [vaultManager, timelock, compoundV3Provider, aaveV3Provider, dolomiteProvider, morphoProvider] =
    await Promise.all([
      deployments.get('VaultManager'),
      deployments.get('Timelock'),
      deployments.get('CompoundV3Provider'),
      deployments.get('AaveV3Provider'),
      deployments.get('DolomiteProvider'),
      deployments.get('MorphoProvider'),
    ]);

  const providers = [
    aaveV3Provider.address,
    compoundV3Provider.address,
    dolomiteProvider.address,
    morphoProvider.address
  ];

  const args = [
    usdtAddress,
    name,
    symbol,
    providers,
    WITHDRAW_FEE_PERCENT,
    timelock.address,
    TREASURY_ADDRESS,
  ];

  const usdtRebalancer = await deploy('Rebalancer', {
    from: deployer,
    args: args,
    log: true,
  });

  log(`USDT Rebalancer at ${usdtRebalancer.address}`);
  log('----------------------------------------------------');

  const usdtInstance = await ethers.getContractAt('IERC20', usdtAddress);
  const balance = await usdtInstance.balanceOf(deployer);
  
  const usdtRebalancerInstance = await ethers.getContractAt(
    'Rebalancer',
    usdtRebalancer.address
  );
  await usdtRebalancerInstance.grantRole(OPERATOR_ROLE, vaultManager.address);
  
  if (balance >= initialDeposit) {
    await usdtInstance.approve(usdtRebalancer.address, initialDeposit);
    await usdtRebalancerInstance.setupVault(initialDeposit);
    log(`✅ Setup vault completed with ${ethers.formatUnits(initialDeposit, 6)} USDT`);
  } else {
    log(`⚠️  Insufficient USDT balance for setup. Current: ${ethers.formatUnits(balance, 6)} USDT, required: ${ethers.formatUnits(initialDeposit, 6)} USDT`);
    log(`⚠️  Please call setupVault(${initialDeposit}) manually after funding the vault`);
  }

  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(usdtRebalancer.address, args);
  }
};

export default deployUsdtVault;
deployUsdtVault.tags = ['all', 'usdt-vault'];
deployUsdtVault.dependencies = ['vault-manager', 'providers', 'timelock', 'dolomite-provider', 'morpho-provider'];
