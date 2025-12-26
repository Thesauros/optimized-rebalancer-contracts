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

const deployDaiVault: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const name = 'Thesauros DAI Vault';
  const symbol = 'tDAI';

  const daiAddress = tokenAddresses.DAI;

  const initialDeposit = ethers.parseEther('1'); // Be sure that you have the balance available in the deployer account

  log('----------------------------------------------------');
  log('Deploying DAI Rebalancer...');

  const [vaultManager, timelock, aaveV3Provider] = await Promise.all([
    deployments.get('VaultManager'),
    deployments.get('Timelock'),
    deployments.get('AaveV3Provider'),
  ]);

  const providers = [aaveV3Provider.address];

  const args = [
    daiAddress,
    name,
    symbol,
    providers,
    WITHDRAW_FEE_PERCENT,
    timelock.address,
    TREASURY_ADDRESS,
  ];

  const daiRebalancer = await deploy('Rebalancer', {
    from: deployer,
    args: args,
    log: true,
  });

  log(`DAI Rebalancer at ${daiRebalancer.address}`);
  log('----------------------------------------------------');

  const daiInstance = await ethers.getContractAt('IERC20', daiAddress);
  await daiInstance.approve(daiRebalancer.address, initialDeposit);

  const daiRebalancerInstance = await ethers.getContractAt(
    'Rebalancer',
    daiRebalancer.address
  );
  await daiRebalancerInstance.grantRole(OPERATOR_ROLE, vaultManager.address);
  await daiRebalancerInstance.setupVault(initialDeposit);

  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(daiRebalancer.address, args);
  }
};

export default deployDaiVault;
deployDaiVault.tags = ['all', 'dai-vault'];
// deployDaiVault.dependencies = ['vault-manager', 'providers', 'timelock'];
