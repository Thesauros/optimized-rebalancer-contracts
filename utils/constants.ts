import { ethers } from 'hardhat';

export const tokenAddresses = {
  USDC: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
  USDT: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
};

export const cometTokens = {
  cUSDC: '0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf',
  cUSDT: '0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07',
};

export const cometPairs = [
  {
    asset: tokenAddresses.USDC,
    cToken: cometTokens.cUSDC,
  },
  {
    asset: tokenAddresses.USDT,
    cToken: cometTokens.cUSDT,
  },
];

export const morphoVaults = [
  {
    strategy: 'SteakhouseHighYield',
    vaultAddress: '0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA',
  },
  {
    strategy: 'YearnDegen',
    vaultAddress: '0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9',
  },
  {
    strategy: 'GauntletCore',
    vaultAddress: '0x7e97fa6893871A2751B5fE961978DCCb2c201E65',
  },
  {
    strategy: 'Hyperithm',
    vaultAddress: '0x4B6F1C9E5d470b97181786b26da0d0945A7cf027',
  },
];

export const ARBITRUM_CHAIN_ID = 42161n;

export const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS;
export const WITHDRAW_FEE_PERCENT = BigInt(
  process.env.WITHDRAW_FEE_PERCENT || '0'
);
export const TIMELOCK_DELAY = Number(process.env.TIMELOCK_DELAY || '1800');

export const ADMIN_ROLE = ethers.ZeroHash;
export const OPERATOR_ROLE = ethers.id('OPERATOR_ROLE');
export const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');
