import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface NetworkConfig {
  name: string;
  chainId: number;
  rpcUrl: string;
  explorer: string;
}

const networks: { [key: string]: NetworkConfig } = {
  arbitrumOne: {
    name: 'Arbitrum One',
    chainId: 42161,
    rpcUrl: 'https://arb1.arbitrum.io/rpc',
    explorer: 'https://arbiscan.io'
  },
  arbitrumSepolia: {
    name: 'Arbitrum Sepolia',
    chainId: 421614,
    rpcUrl: 'https://sepolia-rollup.arbitrum.io/rpc',
    explorer: 'https://sepolia.arbiscan.io'
  },
  mainnet: {
    name: 'Ethereum Mainnet',
    chainId: 1,
    rpcUrl: 'https://eth.llamarpc.com',
    explorer: 'https://etherscan.io'
  },
  polygon: {
    name: 'Polygon',
    chainId: 137,
    rpcUrl: 'https://polygon-rpc.com',
    explorer: 'https://polygonscan.com'
  }
};

async function main() {
  const args = process.argv.slice(2);
  const targetNetwork = args[0];

  if (!targetNetwork) {
    console.log('Usage: npm run update-config <network>');
    console.log('Available networks:');
    for (const [key, network] of Object.entries(networks)) {
      console.log(`  ${key} - ${network.name} (Chain ID: ${network.chainId})`);
    }
    process.exit(1);
  }

  if (!networks[targetNetwork]) {
    console.error(`Unknown network: ${targetNetwork}`);
    console.log('Available networks:', Object.keys(networks).join(', '));
    process.exit(1);
  }

  const network = networks[targetNetwork];
  console.log(`Updating configuration for ${network.name}...`);

  // Update hardhat config
  await updateHardhatConfig(targetNetwork, network);

  // Update environment variables
  await updateEnvFile(targetNetwork, network);

  // Update package.json scripts
  await updatePackageScripts(targetNetwork);

  console.log(`Configuration updated for ${network.name}!`);
  console.log(`\nNext steps:`);
  console.log(`1. Update your .env file with the correct RPC URL`);
  console.log(`2. Deploy contracts to ${network.name}`);
  console.log(`3. Update deployed-vaults.json with new addresses`);
  console.log(`4. Run monitoring scripts with: npm run monitor`);
}

async function updateHardhatConfig(networkKey: string, network: NetworkConfig) {
  const configPath = path.join(__dirname, '..', 'hardhat.config.ts');
  
  if (!fs.existsSync(configPath)) {
    console.log('hardhat.config.ts not found, skipping...');
    return;
  }

  let configContent = fs.readFileSync(configPath, 'utf8');
  
  // Update network configuration
  const networkConfig = `
  ${networkKey}: {
    url: process.env.${networkKey.toUpperCase()}_RPC_URL || "${network.rpcUrl}",
    chainId: ${network.chainId},
    accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    verify: {
      etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY
      }
    }
  }`;

  // Replace or add network configuration
  if (configContent.includes(`${networkKey}: {`)) {
    // Update existing network config
    const regex = new RegExp(`${networkKey}:\\s*{[^}]+}`, 's');
    configContent = configContent.replace(regex, networkConfig.trim());
  } else {
    // Add new network config
    const networksMatch = configContent.match(/networks:\s*{([^}]+)}/s);
    if (networksMatch) {
      const networksContent = networksMatch[1];
      const updatedNetworks = networksContent + ',\n  ' + networkConfig.trim();
      configContent = configContent.replace(networksMatch[0], `networks: {\n  ${updatedNetworks}\n}`);
    }
  }

  fs.writeFileSync(configPath, configContent);
  console.log(`Updated hardhat.config.ts for ${networkKey}`);
}

async function updateEnvFile(networkKey: string, network: NetworkConfig) {
  const envPath = path.join(__dirname, '..', '.env');
  const envExamplePath = path.join(__dirname, '..', '.env.example');
  
  // Create .env.example if it doesn't exist
  if (!fs.existsSync(envExamplePath)) {
    const envExampleContent = `# Network Configuration
${networkKey.toUpperCase()}_RPC_URL=${network.rpcUrl}

# Private key for transactions
PRIVATE_KEY=your_private_key_here

# API Keys
ETHERSCAN_API_KEY=your_etherscan_api_key
ALCHEMY_API_KEY=your_alchemy_api_key

# Optional: Other network RPC URLs
ARBITRUM_ONE_RPC_URL=https://arb1.arbitrum.io/rpc
ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
MAINNET_RPC_URL=https://eth.llamarpc.com
POLYGON_RPC_URL=https://polygon-rpc.com
`;
    fs.writeFileSync(envExamplePath, envExampleContent);
    console.log('Created .env.example file');
  }

  // Update .env if it exists
  if (fs.existsSync(envPath)) {
    let envContent = fs.readFileSync(envPath, 'utf8');
    
    // Add or update RPC URL
    const rpcUrlLine = `${networkKey.toUpperCase()}_RPC_URL=${network.rpcUrl}`;
    const rpcUrlRegex = new RegExp(`${networkKey.toUpperCase()}_RPC_URL=.*`, 'g');
    
    if (rpcUrlRegex.test(envContent)) {
      envContent = envContent.replace(rpcUrlRegex, rpcUrlLine);
    } else {
      envContent += `\n${rpcUrlLine}`;
    }
    
    fs.writeFileSync(envPath, envContent);
    console.log(`Updated .env file for ${networkKey}`);
  } else {
    console.log('No .env file found. Please create one based on .env.example');
  }
}

async function updatePackageScripts(networkKey: string) {
  const packagePath = path.join(__dirname, '..', 'package.json');
  
  if (!fs.existsSync(packagePath)) {
    console.log('package.json not found, skipping...');
    return;
  }

  const packageContent = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  
  // Update monitoring scripts to use the new network
  const scripts = packageContent.scripts || {};
  
  // Update network in monitoring scripts
  for (const [scriptName, scriptCommand] of Object.entries(scripts)) {
    if (typeof scriptCommand === 'string' && scriptCommand.includes('--network')) {
      scripts[scriptName] = scriptCommand.replace(/--network\s+\w+/, `--network ${networkKey}`);
    }
  }
  
  packageContent.scripts = scripts;
  fs.writeFileSync(packagePath, JSON.stringify(packageContent, null, 2));
  console.log(`Updated package.json scripts for ${networkKey}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
