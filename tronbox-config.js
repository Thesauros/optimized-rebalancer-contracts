require('dotenv').config();

module.exports = {
  contracts_directory: './tron-contracts',
  contracts_build_directory: './build/tron-contracts',
  compilers: {
    solc: {
      version: '0.8.20',
      settings: {
        optimizer: {
          enabled: true,
          runs: 200,
        },
        evmVersion: 'istanbul',
      },
    },
  },
};

