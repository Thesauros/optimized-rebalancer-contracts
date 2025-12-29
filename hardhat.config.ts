import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-foundry';
import 'hardhat-contract-sizer';
import 'hardhat-deploy';
import 'hardhat-deploy-ethers';
import '@nomicfoundation/hardhat-verify';
import 'dotenv/config';

import { networkConfig } from './network-config';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.23',
    settings: { optimizer: { enabled: true, runs: 1 } },
  },
  mocha: {
    timeout: 150000000,
  },
  contractSizer: { runOnCompile: false },
  networks: networkConfig,
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY!,
  },
  namedAccounts: {
    deployer: 0,
  },
};

export default config;
