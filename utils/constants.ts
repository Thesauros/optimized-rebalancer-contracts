import { ethers } from 'hardhat';
// ARBITRUM ONE TOKEN ADDRESSES
export const tokenAddresses = {
  USDT: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
  USDC: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
};

export const cometTokens = {
  cUSDT: '0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07',
  cUSDC: '0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf',
};

export const cometPairs = [
  {
    asset: tokenAddresses.USDT,
    cToken: cometTokens.cUSDT,
  },
  {
    asset: tokenAddresses.USDC,
    cToken: cometTokens.cUSDC,
  },
];

// Ethena Protocol addresses for Arbitrum network
// Note: Ethena Protocol is planning to deploy on Arbitrum via Converge blockchain
// These addresses will be updated when Ethena Protocol is deployed on Arbitrum
// For now, we use mock contracts for testing
export const ethenaAddresses = {
  USDe: '0x4c9edd5852cd905f086c759e8383e09bff1e68b3', // Will be set after mock deployment
  staking: '0x0000000000000000000000000000000000000000', // Will be set after mock deployment
};

export const ethenaPairs = [
  {
    asset: tokenAddresses.USDT,
    usdeToken: ethenaAddresses.USDe,
    stakingContract: ethenaAddresses.staking,
  },
  {
    asset: tokenAddresses.USDC,
    usdeToken: ethenaAddresses.USDe,
    stakingContract: ethenaAddresses.staking,
  },
];

// Morpho Blue Protocol addresses for Arbitrum network
export const morphoAddresses = {
  morpho: '0x6c247b1f6182318877311737bac0844baa518f5e'
};

// Available MetaMorpho vaults on Arbitrum
export const morphoVaults = [
  {
    strategy: 'Steakhouse Financial',
    vaultAddress: '0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA',
  },
  {
    strategy: 'MEV Capital',
    vaultAddress: '0xa60643c90A542A95026C0F1dbdB0615fF42019Cf',
  },
  {
    strategy: 'Hyperithm',
    vaultAddress: '0x4B6F1C9E5d470b97181786b26da0d0945A7cf027',
  },
  {
    strategy: 'Gauntlet Prime',
    vaultAddress: '0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed',
  },
  {
    strategy: 'Gauntlet Core',
    vaultAddress: '0x7e97fa6893871A2751B5fE961978DCCb2c201E65',
  }
];


export const ARBITRUM_CHAIN_ID = 42161n;

export const TREASURY_ADDRESS = '0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D';

export const ADMIN_ROLE = '0x50662aEDe1e73a1f6ffc6b3bBB1EA5C4D8083eD5';
export const OPERATOR_ROLE = ethers.id('OPERATOR_ROLE');
export const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');

export const WITHDRAW_FEE_PERCENT = ethers.parseEther('0.001'); // 0.1%

// Dolomite Protocol addresses for Arbitrum network
export const dolomiteAddresses = {
  margin: '0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072', // DolomiteMargin
  getter: '0x9381942De7A66fdB4741272EaB4fc0A362F7a16a', // DolomiteGetter
  proxy: '0xAdB9D68c613df4AA363B42161E1282117C7B9594', // DepositWithdrawalProxy
};

export const dolomitePairs = [
  {
    asset: tokenAddresses.USDC,
    marketId: 0, // USDC market ID in Dolomite
  },
  {
    asset: tokenAddresses.USDT,
    marketId: 1, // USDT market ID in Dolomite
  },
];