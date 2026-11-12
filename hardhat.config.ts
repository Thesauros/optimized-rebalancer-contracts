import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-foundry';
import 'hardhat-deploy';
import 'dotenv/config';

import { networkConfig } from './network-config';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.33',
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  mocha: {
    timeout: 150000000,
  },
  networks: networkConfig,
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY!,
    customChains: [
      {
        network: 'plasma',
        chainId: 9745,
        urls: {
          // plasmascan is Etherscan V2-only; route through the V2 multichain endpoint
          apiURL: 'https://api.etherscan.io/v2/api?chainid=9745',
          browserURL: 'https://plasmascan.to',
        },
      },
      {
        network: 'monad',
        chainId: 143,
        urls: {
          // monadscan via the Etherscan V2 multichain endpoint
          apiURL: 'https://api.etherscan.io/v2/api?chainid=143',
          browserURL: 'https://monadscan.com',
        },
      },
    ],
  },
  namedAccounts: {
    deployer: 0,
  },
};

export default config;
