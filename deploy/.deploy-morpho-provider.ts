import { ethers } from "hardhat";
import { MorphoProvider } from "../typechain-types";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying MorphoProvider with account:", deployer.address);

    // Get ProviderManager address from environment or use default
    const providerManagerAddress = process.env.PROVIDER_MANAGER_ADDRESS;
    if (!providerManagerAddress) {
        throw new Error("PROVIDER_MANAGER_ADDRESS environment variable is required");
    }

    console.log("ProviderManager address:", providerManagerAddress);

    // Deploy MorphoProvider
    const MorphoProviderFactory = await ethers.getContractFactory("MorphoProvider");
    const morphoProvider = await MorphoProviderFactory.deploy(providerManagerAddress);
    await morphoProvider.waitForDeployment();

    const morphoProviderAddress = await morphoProvider.getAddress();
    console.log("MorphoProvider deployed to:", morphoProviderAddress);

    // Verify the deployment
    const identifier = await morphoProvider.getIdentifier();
    console.log("Provider identifier:", identifier);

    // Save deployment info
    const deploymentInfo = {
        network: await ethers.provider.getNetwork(),
        morphoProvider: {
            address: morphoProviderAddress,
            identifier: identifier,
            providerManager: providerManagerAddress,
            deployer: deployer.address,
            blockNumber: await ethers.provider.getBlockNumber(),
            timestamp: new Date().toISOString()
        }
    };

    console.log("Deployment completed successfully!");
    console.log("Deployment info:", JSON.stringify(deploymentInfo, null, 2));

    // Instructions for next steps
    console.log("\nNext steps:");
    console.log("1. Configure MorphoProvider in ProviderManager:");
    console.log("   - Set yield tokens for supported assets");
    console.log("   - Set markets for asset configurations");
    console.log("2. Run setup script: npm run setup:morpho-provider");
    console.log("3. Verify deployment: npm run verify:morpho-provider");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
