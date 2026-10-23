import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { chainConfigs } from '../../utils/constants';
import { verify } from '../../utils/verify';

/** Deploy only the V2 providers; existing vault registration is a separate governance action. */
const deployGauntletV2Provider: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, deployments, getNamedAccounts } = hre;
  const chainId =
    hre.network.name === 'hardhat' && process.env.FORK_CHAIN_ID
      ? BigInt(process.env.FORK_CHAIN_ID)
      : (await ethers.provider.getNetwork()).chainId;
  const config = chainConfigs[Number(chainId)];
  const strategies = config?.morphoVaults.filter(({ version }) => version === 2) ?? [];
  if (!strategies.length) {
    throw new Error(`No Morpho V2 vaults configured for chain ${chainId}`);
  }

  const { deployer } = await getNamedAccounts();
  const dryRun = hre.network.name === 'hardhat' || process.env.DRY_RUN === '1';
  for (const { strategy, vaultAddress } of strategies) {
    const source = await ethers.getContractAt('IMorphoVaultV2', vaultAddress);
    if ((await source.asset()).toLowerCase() !== config.asset.toLowerCase()) {
      throw new Error(`Morpho V2 asset mismatch for ${strategy} on chain ${chainId}`);
    }
    const deployment = await deployments.deploy(`${strategy}MorphoProvider`, {
      contract: 'MorphoV2Provider',
      from: deployer,
      args: [vaultAddress],
      log: true,
      waitConfirmations: dryRun ? 0 : 2,
    });
    if (!dryRun) await verify(deployment.address, [vaultAddress]);
  }
};

deployGauntletV2Provider.tags = ['gauntlet-v2-provider'];
export default deployGauntletV2Provider;
