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
    apiKey: process.env.ETHERSCAN_API_KEY || '',
    customChains: [
      {
        network: "arbitrumOne",
        chainId: 42161,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=42161",
          browserURL: "https://arbiscan.io"
        }
      },
      {
        network: "arbitrumSepolia",
        chainId: 421614,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=421614",
          browserURL: "https://sepolia.arbiscan.io"
        }
      }
    ]
  },
  namedAccounts: {
    deployer: 0,
  },
};

export default config;
