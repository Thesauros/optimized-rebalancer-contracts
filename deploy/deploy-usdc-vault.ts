import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  MAINNET_CHAIN_ID,
  BASE_CHAIN_ID,
  ARBITRUM_CHAIN_ID,
  PLASMA_CHAIN_ID,
  MONAD_CHAIN_ID,
  TREASURY_ADDRESS,
  MANAGEMENT_FEE_PERCENT,
  PERFORMANCE_FEE_PERCENT,
  TIMELOCK_DELAY,
  chainConfigs,
} from '../utils/constants';
import { verify } from '../utils/verify';

const deployUsdcVault: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  // @ts-ignore
  const { getNamedAccounts, deployments } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const chainId = (await ethers.provider.getNetwork()).chainId;
  const chainConfig = chainConfigs[Number(chainId)];
  if (!chainConfig) {
    throw new Error(`Unsupported chain id: ${chainId}`);
  }
  if (!TREASURY_ADDRESS) {
    throw new Error('TREASURY_ADDRESS is not set');
  }
  // A forked run reaches a live chain id but must neither wait for
  // confirmations that never come nor submit anything to a block explorer.
  const dryRun = hre.network.name === 'hardhat' || process.env.DRY_RUN === '1';
  const isLive =
    !dryRun &&
    (chainId === MAINNET_CHAIN_ID ||
      chainId === BASE_CHAIN_ID ||
      chainId === ARBITRUM_CHAIN_ID ||
      chainId === PLASMA_CHAIN_ID ||
      chainId === MONAD_CHAIN_ID);
  const waitConfirmations = isLive ? 2 : 0;

  const name = chainConfig.vaultName;
  const symbol = chainConfig.vaultSymbol;

  const assetAddress = chainConfig.asset;

  const assetInstance = await ethers.getContractAt('IERC20', assetAddress);
  const assetMetadata = await ethers.getContractAt(
    'IERC20Metadata',
    assetAddress,
  );
  const minAssets = ethers.parseUnits('1', await assetMetadata.decimals()); // Be sure that you have the balance available in the deployer account

  const providers: string[] = [];

  /*//////////////////////////////////////////////////////////////
                            DEPLOY PROVIDERS
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying ProviderManager...');

  const providerManager = await deploy('ProviderManager', {
    from: deployer,
    args: [deployer],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`ProviderManager at ${providerManager.address}`);

  const providerManagerInstance = await ethers.getContractAt(
    'ProviderManager',
    providerManager.address,
  );

  log('----------------------------------------------------');
  log('Setting up yield tokens...');

  for (const { asset, cToken } of chainConfig.cometPairs) {
    await providerManagerInstance
      .setYieldToken('Compound_V3_Provider', asset, cToken)
      .then((tx) => tx.wait());
  }

  if (isLive) {
    await verify(providerManager.address, [deployer]);
  }

  log('----------------------------------------------------');
  log('Deploying AaveV3 and CompoundV3 providers...');

  const providersToDeploy = [
    ...(chainConfig.cometPairs.length > 0 ? ['CompoundV3Provider'] : []),
    'AaveV3Provider',
  ];

  for (const providerName of providersToDeploy) {
    const args =
      providerName === 'CompoundV3Provider'
        ? [providerManager.address]
        : [chainConfig.aavePoolAddressesProvider];

    const provider = await deploy(providerName, {
      from: deployer,
      args: args,
      log: true,
      waitConfirmations: waitConfirmations,
    });

    log('----------------------------------------------------');
    log(`${providerName} at ${provider.address}`);

    providers.push(provider.address);

    if (isLive) {
      await verify(provider.address, args);
    }
  }

  log('----------------------------------------------------');
  log('Deploying Morpho providers...');

  for (const { strategy, vaultAddress } of chainConfig.morphoVaults) {
    const deploymentName = `${strategy}MorphoProvider`;
    const provider = await deploy(deploymentName, {
      contract: 'MorphoProvider',
      from: deployer,
      args: [vaultAddress],
      log: true,
      waitConfirmations: waitConfirmations,
    });

    log('----------------------------------------------------');
    log(`MorphoProvider for ${strategy} strategy at ${provider.address}`);

    providers.push(provider.address);

    if (isLive) {
      await verify(provider.address, [vaultAddress]);
    }
  }

  /*//////////////////////////////////////////////////////////////
                            DEPLOY TIMELOCK
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying Timelock...');

  const timelock = await deploy('Timelock', {
    from: deployer,
    args: [deployer, TIMELOCK_DELAY],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`Timelock at ${timelock.address}`);

  if (isLive) {
    await verify(timelock.address, [deployer, TIMELOCK_DELAY]);
  }

  /*//////////////////////////////////////////////////////////////
                         DEPLOY USDC REBALANCER
  //////////////////////////////////////////////////////////////*/

  log('----------------------------------------------------');
  log('Deploying USDC Rebalancer...');

  const implementation = await deploy('USDCRebalancerImplementation', {
    contract: 'Rebalancer',
    from: deployer,
    args: [],
    log: true,
    waitConfirmations: waitConfirmations,
  });

  log('----------------------------------------------------');
  log(`Implementation at ${implementation.address}`);

  // Initialize calldata for the proxy.
  const rebalancerArtifact = await hre.artifacts.readArtifact('Rebalancer');
  const initCalldata = new ethers.Interface(
    rebalancerArtifact.abi,
  ).encodeFunctionData('initialize', [
    TREASURY_ADDRESS,
    timelock.address,
    assetAddress,
    name,
    symbol,
    providers,
    TREASURY_ADDRESS,
    MANAGEMENT_FEE_PERCENT,
    PERFORMANCE_FEE_PERCENT,
    minAssets,
  ]);

  /*
   * Sniping protection. On 2026-08-05 a third party initialized the Arbitrum
   * proxy 2 seconds after creation. Constructor-time initialization is not an
   * option: the init flow delegatecalls a provider which calls back
   * vault.asset(), and the proxy has no code during its own constructor.
   *
   * Countermeasure: VaultFactory creates the proxy and calls initialize inside
   * one transaction. The three-transaction pipeline this replaced depended on
   * first-come-first-served ordering, which Ethereum mainnet does not provide —
   * there a builder can place somebody else's initialize between the proxy
   * deployment and ours.
   */
  const existingProxy = await hre.deployments
    .get('USDCRebalancerProxy')
    .catch(() => null);

  let proxyAddress: string;

  if (existingProxy) {
    proxyAddress = existingProxy.address;
    const probe = new ethers.Contract(
      proxyAddress,
      [
        'function name() view returns (string)',
        'function getTimelock() view returns (address)',
      ],
      ethers.provider,
    );
    const [proxyName, proxyTimelock] = await Promise.all([
      probe.name().catch(() => ''),
      probe.getTimelock().catch(() => ethers.ZeroAddress),
    ]);
    if (
      proxyName !== name ||
      proxyTimelock.toLowerCase() !== timelock.address.toLowerCase()
    ) {
      throw new Error(
        `Recorded proxy ${proxyAddress} does not look like our initialized vault — inspect manually before retrying`,
      );
    }
    log('----------------------------------------------------');
    log(`Reusing initialized USDCRebalancerProxy at ${proxyAddress}`);
  } else {
    log('----------------------------------------------------');
    log('Deploying VaultFactory...');

    const factory = await deploy('VaultFactory', {
      from: deployer,
      args: [],
      log: true,
      waitConfirmations: waitConfirmations,
    });

    log('----------------------------------------------------');
    log(`VaultFactory at ${factory.address}`);

    if (isLive) {
      await verify(factory.address, []);
    }

    const factoryInstance = await ethers.getContractAt(
      'VaultFactory',
      factory.address,
    );
    const assetInstance = await ethers.getContractAt('IERC20', assetAddress);

    // initialize pulls minAssets from its own msg.sender, which is the factory;
    // the factory in turn pulls it from the deployer, so the seed has to be there.
    const seedBalance = await assetInstance.balanceOf(deployer);
    if (seedBalance < minAssets) {
      throw new Error(
        `Deployer ${deployer} holds ${seedBalance} of ${assetAddress}, needs ${minAssets} for the seed deposit`,
      );
    }
    const approveTx = await assetInstance.approve(factory.address, minAssets);
    await approveTx.wait(waitConfirmations);

    // buffer over the estimate: this single tx carries the proxy creation, the
    // seed transfer and the whole initialize flow, and a mid-flight revert here
    // means redeploying the vault from scratch.
    const gasEstimate = await factoryInstance.deployAndInitialize.estimateGas(
      implementation.address,
      TREASURY_ADDRESS,
      deployer,
      assetAddress,
      minAssets,
      initCalldata,
    );

    const deployTx = await factoryInstance.deployAndInitialize(
      implementation.address,
      TREASURY_ADDRESS,
      deployer,
      assetAddress,
      minAssets,
      initCalldata,
      { gasLimit: (gasEstimate * 13n) / 10n },
    );

    log('----------------------------------------------------');
    log(`Proxy deploy + initialize sent as one tx: ${deployTx.hash}`);

    const receipt = await deployTx.wait(waitConfirmations);
    if (!receipt || receipt.status !== 1) {
      throw new Error('deployAndInitialize tx failed');
    }

    const deployedEvent = receipt.logs
      .map((entry) => {
        try {
          return factoryInstance.interface.parseLog(entry);
        } catch {
          return null;
        }
      })
      .find((parsed) => parsed?.name === 'VaultDeployed');
    if (!deployedEvent) {
      throw new Error(
        `VaultDeployed event missing from ${receipt.hash} — inspect the tx before retrying`,
      );
    }
    proxyAddress = deployedEvent.args.vault;

    // sanity: the vault must carry the parameters we encoded
    const postInit = new ethers.Contract(
      proxyAddress,
      [
        'function name() view returns (string)',
        'function getTimelock() view returns (address)',
      ],
      ethers.provider,
    );
    const [postName, postTimelock] = await Promise.all([
      postInit.name(),
      postInit.getTimelock(),
    ]);
    if (
      postName !== name ||
      postTimelock.toLowerCase() !== timelock.address.toLowerCase()
    ) {
      throw new Error(
        `Proxy ${proxyAddress} does not match the intended vault — not recording it`,
      );
    }

    // persist a hardhat-deploy record so reruns/verifications work
    const fs = await import('fs');
    const path = await import('path');
    const tupArtifact =
      await hre.artifacts.readArtifact('TransparentUpgradeableProxy');
    const recordPath = path.join(
      hre.config.paths.deployments,
      hre.network.name,
      'USDCRebalancerProxy.json',
    );
    fs.writeFileSync(
      recordPath,
      JSON.stringify(
        {
          address: proxyAddress,
          abi: tupArtifact.abi,
          args: [implementation.address, TREASURY_ADDRESS, '0x'],
          transactionHash: receipt.hash,
          receipt,
        },
        null,
        2,
      ),
    );

    log('----------------------------------------------------');
    log(`Proxy at ${proxyAddress} (deployed and initialized atomically)`);
  }

  if (isLive) {
    await verify(implementation.address, []);
    await verify(proxyAddress, [implementation.address, TREASURY_ADDRESS, '0x']);
  }
};

export default deployUsdcVault;
deployUsdcVault.tags = ['all', 'usdc-vault'];
