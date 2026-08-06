// BASE_RPC_URL takes precedence: the Alchemy app baked into the fallback
// URL can be inactive, and the env var lets us point at any healthy RPC.
export const BASE_URL =
  process.env.BASE_RPC_URL ??
  `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_PROJECT_ID}`;

// The ARBITRUM_RPC_URL in .env points at the same dead Alchemy app as the
// Base fallback, so alchemy URLs are ignored here; the official endpoint is
// primary (publicnode's free tier rejects the archive calls hardhat-deploy makes).
export const ARBITRUM_URL =
  process.env.ARBITRUM_RPC_URL &&
  !process.env.ARBITRUM_RPC_URL.includes('alchemy.com')
    ? process.env.ARBITRUM_RPC_URL
    : 'https://arb1.arbitrum.io/rpc';

export const networkConfig = {
  localhost: {
    chainId: 31337,
  },
  hardhat: {
    forking: {
      url: BASE_URL,
    },
  },
  base: {
    url: BASE_URL,
    accounts: process.env.DEPLOYER_PRIVATE_KEY
      ? [process.env.DEPLOYER_PRIVATE_KEY]
      : [],
    chainId: 8453,
    // 0.003 Gwei used to clear, but Base base fee fluctuates above it;
    // 'auto' lets hardhat pick EIP-1559 fees from the node.
    gasPrice: 'auto' as const,
  },
  arbitrum: {
    url: ARBITRUM_URL,
    accounts: process.env.DEPLOYER_PRIVATE_KEY
      ? [process.env.DEPLOYER_PRIVATE_KEY]
      : [],
    chainId: 42161,
    gasPrice: 'auto' as const,
  },
};