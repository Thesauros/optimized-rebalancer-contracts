import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID } from '../utils/constants';
import { verify } from '../utils/verify';

const deployEthenaMocks: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying Ethena Mock contracts for testing...');

  // Deploy MockUSDe token
  const mockUSDe = await deploy('MockUSDe', {
    from: deployer,
    args: [],
    log: true,
  });

  log(`MockUSDe deployed at ${mockUSDe.address}`);

  // Deploy MockEthenaStaking
  const mockEthenaStaking = await deploy('MockEthenaStaking', {
    from: deployer,
    args: [mockUSDe.address], // USDe token address
    log: true,
  });

  log(`MockEthenaStaking deployed at ${mockEthenaStaking.address}`);

  // Verify contracts on Arbitrum
  if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
    await verify(mockUSDe.address, []);
    await verify(mockEthenaStaking.address, [mockUSDe.address]);
  }

  log('----------------------------------------------------');
  log('Ethena Mock contracts deployment completed');
  log(`Update constants.ts with these addresses:`);
  log(`USDe: ${mockUSDe.address}`);
  log(`staking: ${mockEthenaStaking.address}`);
};

export default deployEthenaMocks;
deployEthenaMocks.tags = ['all', 'ethena-mocks'];
deployEthenaMocks.dependencies = [];
