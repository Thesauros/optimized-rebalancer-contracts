import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID } from '../utils/constants';
import { verify } from '../utils/verify';

const deployTimelock: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying Timelock...');

  const halfHour = 1800;

  const timelock = await deploy('Timelock', {
    from: deployer,
    args: [deployer, halfHour],
    log: true,
  });

  log(`Timelock at ${timelock.address}`);

  log('----------------------------------------------------');

  const chainId = (await ethers.provider.getNetwork()).chainId;

  if (chainId === ARBITRUM_CHAIN_ID) {
    await verify(timelock.address, [deployer, halfHour]);
  }
};

export default deployTimelock;
deployTimelock.tags = ['all', 'timelock'];
