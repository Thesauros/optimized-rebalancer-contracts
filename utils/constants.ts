import { ethers } from 'hardhat';

export const BASE_CHAIN_ID = 8453n;
export const ARBITRUM_CHAIN_ID = 42161n;
export const PLASMA_CHAIN_ID = 9745n;

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

export interface ChainConfig {
  asset: string;
  vaultName: string;
  vaultSymbol: string;
  aavePoolAddressesProvider: string;
  cometPairs: { asset: string; cToken: string }[];
  morphoVaults: { strategy: string; vaultAddress: string }[];
}

export const chainConfigs: Record<number, ChainConfig> = {
  // Base
  8453: {
    asset: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    vaultName: 'Thesauros USDC Vault',
    vaultSymbol: 'tUSDC',
    aavePoolAddressesProvider: '0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D',
    cometPairs: [
      {
        asset: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
        cToken: '0xb125E6687d4313864e53df431d5425969c15Eb2F',
      },
    ],
    morphoVaults: [
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
    ],
  },
  // Arbitrum One
  42161: {
    asset: '0xaf88d065e77c8cc2239327c5edb3a432268e5831',
    vaultName: 'Thesauros USDC Vault',
    vaultSymbol: 'tUSDC',
    aavePoolAddressesProvider: '0xa97684ead0e402dc232d5a977953df7ecbab3cdb',
    cometPairs: [
      {
        asset: '0xaf88d065e77c8cc2239327c5edb3a432268e5831',
        cToken: '0x9c4ec768c28520b50860ea7a15bd7213a9ff58bf',
      },
    ],
    morphoVaults: [
      {
        strategy: 'SteakhouseHighYield',
        vaultAddress: '0x5c0c306aaa9f877de636f4d5822ca9f2e81563ba',
      },
      {
        strategy: 'SteakhousePrime',
        vaultAddress: '0x250cf7c82bac7cb6cf899b6052979d4b5ba1f9ca',
      },
      {
        strategy: 'GauntletCore',
        vaultAddress: '0x7e97fa6893871a2751b5fe961978dccb2c201e65',
      },
    ],
  },
  // Plasma (Aave-only strategy, USDT0 asset)
  9745: {
    asset: '0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb',
    vaultName: 'Thesauros USDT0 Vault',
    vaultSymbol: 'tUSDT0',
    aavePoolAddressesProvider: '0x061D8e131F26512348ee5FA42e2DF1bA9d6505E9',
    cometPairs: [],
    morphoVaults: [],
  },
};
