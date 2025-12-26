import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  ARBITRUM_CHAIN_ID,
  TREASURY_ADDRESS,
  WITHDRAW_FEE_PERCENT,
  OPERATOR_ROLE,
  tokenAddresses,
} from '../utils/constants';
import { verify } from '../utils/verify';

const deployWethVault: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const name = 'Thesauros WETH Vault';
  const symbol = 'tWETH';

  const wethAddress = tokenAddresses.WETH;

  const initialDeposit = ethers.parseEther('0.0001'); // Be sure that you have the balance available in the deployer account

  log('----------------------------------------------------');
  log('Deploying WETH Rebalancer...');

  const [vaultManager, timelock, compoundV3Provider, aaveV3Provider] =
    await Promise.all([
      deployments.get('VaultManager'),
      deployments.get('Timelock'),
      deployments.get('CompoundV3Provider'),
      deployments.get('AaveV3Provider'),
    ]);

  const providers = [compoundV3Provider.address, aaveV3Provider.address];

  const args = [
    wethAddress,
    name,
    symbol,
    providers,
    WITHDRAW_FEE_PERCENT,
    timelock.address,
    TREASURY_ADDRESS,
  ];

  const wethRebalancer = await deploy('Rebalancer', {
    from: deployer,
    args: args,
    log: true,
  });

  log(`WETH Rebalancer at ${wethRebalancer.address}`);
  log('----------------------------------------------------');

  const wethInstance = await ethers.getContractAt('IWETH', wethAddress);
  await wethInstance.deposit({ value: initialDeposit });
  await wethInstance.approve(wethRebalancer.address, initialDeposit);

  const wethRebalancerInstance = await ethers.getContractAt(
    'Rebalancer',
    wethRebalancer.address
  );
  await wethRebalancerInstance.grantRole(OPERATOR_ROLE, vaultManager.address);
  await wethRebalancerInstance.setupVault(initialDeposit);

  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(wethRebalancer.address, args);
  }
};

export default deployWethVault;
deployWethVault.tags = ['all', 'weth-vault'];
// deployWethVault.dependencies = ['vault-manager', 'providers', 'timelock'];
