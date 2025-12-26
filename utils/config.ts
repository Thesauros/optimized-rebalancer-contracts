import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

export interface VaultConfig {
  address: string;
  name: string;
  symbol: string;
  asset: string;
  status: string;
}

export interface BaseContractConfig {
  address: string;
  status: string;
}

export interface DeployedConfig {
  network: string;
  chainId: number;
  deployedAt: string;
  vaults: { [key: string]: VaultConfig };
  baseContracts: { [key: string]: BaseContractConfig };
  tokenAddresses: { [key: string]: string };
  treasury: string;
}

export interface MonitoringConfig {
  name: string;
  script: string;
  interval: number;
  enabled: boolean;
  description: string;
}

export class ConfigLoader {
  private config: DeployedConfig | null = null;
  private configPath: string;

  constructor(network: string = 'arbitrumOne') {
    this.configPath = path.join(__dirname, '..', 'deployments', network, 'deployed-vaults.json');
  }

  async loadConfig(): Promise<DeployedConfig> {
    if (this.config) {
      return this.config;
    }

    try {
      const configData = fs.readFileSync(this.configPath, 'utf8');
      this.config = JSON.parse(configData);
      return this.config;
    } catch (error) {
      throw new Error(`Failed to load config from ${this.configPath}: ${error}`);
    }
  }

  async getVaultAddresses(): Promise<{ [key: string]: string }> {
    const config = await this.loadConfig();
    const vaultAddresses: { [key: string]: string } = {};
    
    for (const [token, vaultConfig] of Object.entries(config.vaults)) {
      vaultAddresses[`${token} Vault`] = vaultConfig.address;
    }
    
    return vaultAddresses;
  }

  async getTokenAddresses(): Promise<{ [key: string]: string }> {
    const config = await this.loadConfig();
    return config.tokenAddresses;
  }

  async getProviderAddresses(): Promise<{ [key: string]: string }> {
    const config = await this.loadConfig();
    const providerAddresses: { [key: string]: string } = {};
    
    for (const [name, contractConfig] of Object.entries(config.baseContracts)) {
      if (name.includes('Provider')) {
        providerAddresses[name] = contractConfig.address;
      }
    }
    
    return providerAddresses;
  }

  async getBaseContractAddresses(): Promise<{ [key: string]: string }> {
    const config = await this.loadConfig();
    const baseAddresses: { [key: string]: string } = {};
    
    for (const [name, contractConfig] of Object.entries(config.baseContracts)) {
      baseAddresses[name] = contractConfig.address;
    }
    
    return baseAddresses;
  }

  async getVaultManagerAddress(): Promise<string> {
    const config = await this.loadConfig();
    return config.baseContracts.VaultManager.address;
  }

  async getTreasuryAddress(): Promise<string> {
    const config = await this.loadConfig();
    return config.treasury;
  }

  async getNetworkInfo(): Promise<{ network: string; chainId: number }> {
    const config = await this.loadConfig();
    return {
      network: config.network,
      chainId: config.chainId
    };
  }

  async validateConfig(): Promise<boolean> {
    try {
      const config = await this.loadConfig();
      
      // Validate required fields
      if (!config.vaults || Object.keys(config.vaults).length === 0) {
        throw new Error('No vaults found in config');
      }
      
      if (!config.baseContracts || Object.keys(config.baseContracts).length === 0) {
        throw new Error('No base contracts found in config');
      }
      
      if (!config.tokenAddresses || Object.keys(config.tokenAddresses).length === 0) {
        throw new Error('No token addresses found in config');
      }
      
      return true;
    } catch (error) {
      console.error(`Config validation failed: ${error}`);
      return false;
    }
  }

  async getTokenDecimals(): Promise<{ [key: string]: number }> {
    const tokenAddresses = await this.getTokenAddresses();
    const decimals: { [key: string]: number } = {};
    
    // Standard token decimals
    const standardDecimals: { [key: string]: number } = {
      'WETH': 18,
      'USDC': 6,
      'USDT': 6,
      'USDC_e': 6
    };
    
    for (const [token, address] of Object.entries(tokenAddresses)) {
      decimals[token] = standardDecimals[token] || 18; // Default to 18
    }
    
    return decimals;
  }
}

// Default monitoring configuration
export const defaultMonitoringConfigs: MonitoringConfig[] = [
  {
    name: 'Vault Status',
    script: 'scripts/monitor-vaults.ts',
    interval: 300, // 5 minutes
    enabled: true,
    description: 'Monitor TVL, APY, and vault performance'
  },
  {
    name: 'APY Analysis',
    script: 'scripts/monitor-apy-real.ts',
    interval: 600, // 10 minutes
    enabled: true,
    description: 'Compare provider APYs and find opportunities'
  },
  {
    name: 'Event Monitoring',
    script: 'scripts/monitor-events.ts',
    interval: 60, // 1 minute
    enabled: true,
    description: 'Monitor real-time events'
  },
  {
    name: 'Auto Rebalancing',
    script: 'scripts/auto-rebalance.ts',
    interval: 1800, // 30 minutes
    enabled: false,
    description: 'Automatic rebalancing bot'
  }
];

// Export singleton instance
export const configLoader = new ConfigLoader();
