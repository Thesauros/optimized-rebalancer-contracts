import { ethers } from 'hardhat';

export const tokenAddresses = {
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
};

export const cometTokens = {
  cUSDC: '0xb125E6687d4313864e53df431d5425969c15Eb2F',
};

export const cometPairs = [
  {
    asset: tokenAddresses.USDC,
    cToken: cometTokens.cUSDC,
  },
];

export const morphoVaults = [
  {
    strategy: 'SteakhouseHighYield',
    vaultAddress: '0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F',
  },
  {
    strategy: 'SteakhousePrime',
    vaultAddress: '0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2',
  },
  {
    strategy: 'GauntletCore',
    vaultAddress: '0xc0c5689e6f4D256E861F65465b691aeEcC0dEb12',
  },
];

export const BASE_CHAIN_ID = 8453n;

export const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS;

export const MANAGEMENT_FEE_PERCENT = BigInt(
  process.env.MANAGEMENT_FEE_PERCENT || '0'
);
export const PERFORMANCE_FEE_PERCENT = BigInt(
  process.env.PERFORMANCE_FEE_PERCENT || '0'
);

export const TIMELOCK_DELAY = Number(process.env.TIMELOCK_DELAY || '1800');

export const ADMIN_ROLE = ethers.ZeroHash;
export const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');
