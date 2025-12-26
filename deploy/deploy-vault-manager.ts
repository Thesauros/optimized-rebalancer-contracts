import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { ARBITRUM_CHAIN_ID } from '../utils/constants';
import { verify } from '../utils/verify';

const deployVaultManager: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log('----------------------------------------------------');
  log('Deploying VaultManager...');

  const vaultManager = await deploy('VaultManager', {
    from: deployer,
    args: [],
    log: true,
  });

  log(`VaultManager at ${vaultManager.address}`);

  log('----------------------------------------------------');

  const chainId = (await ethers.provider.getNetwork()).chainId;

  if (chainId === ARBITRUM_CHAIN_ID) {
    await verify(vaultManager.address, []);
  }
};

export default deployVaultManager;
deployVaultManager.tags = ['all', 'vault-manager'];
