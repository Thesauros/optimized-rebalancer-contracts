// BASE_RPC_URL takes precedence: the Alchemy app baked into the fallback
// URL can be inactive, and the env var lets us point at any healthy RPC.
export const BASE_URL =
  process.env.BASE_RPC_URL ??
  `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_PROJECT_ID}`;

// The Alchemy app in .env is inactive ("App is inactive"), so Ethereum falls
// back to a public endpoint; override with ETHEREUM_RPC_URL to use a private
// or archive node.
export const MAINNET_URL =
  process.env.ETHEREUM_RPC_URL ?? 'https://ethereum-rpc.publicnode.com';

// Public Arbitrum endpoint as fallback; override with ARBITRUM_RPC_URL.
// The ARBITRUM_RPC_URL in .env points at the same dead Alchemy app as the
// Base fallback, so alchemy URLs are ignored here.
export const ARBITRUM_URL =
  process.env.ARBITRUM_RPC_URL &&
  !process.env.ARBITRUM_RPC_URL.includes('alchemy.com')
    ? process.env.ARBITRUM_RPC_URL
    : 'https://arb1.arbitrum.io/rpc';

export const PLASMA_URL = process.env.PLASMA_RPC_URL ?? 'https://rpc.plasma.to';

export const MONAD_URL = process.env.MONAD_RPC_URL ?? 'https://rpc.monad.xyz';

export const networkConfig = {
  localhost: {
    chainId: 31337,
  },
  hardhat: {
    // Hardhat keeps its own chain id when forking, so a dry run must state
    // which chain it forks for the deploy script to find the right config.
    chainId: process.env.FORK_CHAIN_ID
      ? Number(process.env.FORK_CHAIN_ID)
      : 31337,
    forking: {
      // FORK_RPC_URL lets a dry run fork any supported chain, e.g. Ethereum.
      url: process.env.FORK_RPC_URL ?? BASE_URL,
    },
  },
  mainnet: {
    url: MAINNET_URL,
    accounts: process.env.DEPLOYER_PRIVATE_KEY
      ? [process.env.DEPLOYER_PRIVATE_KEY]
      : [],
    chainId: 1,
    gasPrice: 'auto' as const,
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
  plasma: {
    url: PLASMA_URL,
    accounts: process.env.DEPLOYER_PRIVATE_KEY
      ? [process.env.DEPLOYER_PRIVATE_KEY]
      : [],
    chainId: 9745,
    gasPrice: 'auto' as const,
  },
  monad: {
    url: MONAD_URL,
    accounts: process.env.DEPLOYER_PRIVATE_KEY
      ? [process.env.DEPLOYER_PRIVATE_KEY]
      : [],
    chainId: 143,
    gasPrice: 'auto' as const,
  },
};