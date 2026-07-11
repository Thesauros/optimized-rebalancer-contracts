module.exports = {
  contracts_directory: './.tron-contracts',
  contracts_build_directory: './build/tron-contracts',
  compilers: {
    solc: {
      version: '0.8.24',
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
