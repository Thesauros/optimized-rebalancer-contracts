import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID, ethenaPairs } from '../utils/constants';
import { verify } from '../utils/verify';

const deployEthenaProvider: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying EthenaProvider for Arbitrum network...');
  log('Note: Ethena Protocol is planning to deploy on Arbitrum via Converge blockchain');
  log('Current addresses are placeholders and need to be updated when Ethena is deployed');

  // Get deployed mock contracts
  const mockUSDe = await deployments.get('MockUSDe');
  const mockEthenaStaking = await deployments.get('MockEthenaStaking');

  // Deploy EthenaProvider for each supported asset
  for (const pair of ethenaPairs) {
    // Use mock contracts for testing
    const stakingContract = mockEthenaStaking.address;
    const usdeToken = mockUSDe.address;

    const args = [
      stakingContract,      // ethenaStaking (mock)
      usdeToken,           // usdeToken (mock)
      pair.asset,          // collateralToken (USDT/USDC)
    ];

    const ethenaProvider = await deploy('EthenaProvider', {
      from: deployer,
      args: args,
      log: true,
    });

    log(`EthenaProvider for ${pair.asset} deployed at ${ethenaProvider.address}`);

    if ((await ethers.provider.getNetwork()).chainId === ARBITRUM_CHAIN_ID) {
      await verify(ethenaProvider.address, args);
    }
  }

  log('----------------------------------------------------');
  log('EthenaProvider deployment completed');
};

export default deployEthenaProvider;
deployEthenaProvider.tags = ['all', 'ethena-provider'];
deployEthenaProvider.dependencies = ['ethena-mocks'];
