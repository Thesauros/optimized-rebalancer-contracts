import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import {
  BASE_CHAIN_ID,
  ARBITRUM_CHAIN_ID,
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
  const isLive = chainId === BASE_CHAIN_ID || chainId === ARBITRUM_CHAIN_ID;
  const waitConfirmations = isLive ? 2 : 0;

  const name = 'Thesauros USDC Vault';
  const symbol = 'tUSDC';

  const usdcAddress = chainConfig.usdc;

  const minAssets = ethers.parseUnits('1', 6); // Be sure that you have the balance available in the deployer account

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

  const providersToDeploy = ['CompoundV3Provider', 'AaveV3Provider'];

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
    usdcAddress,
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
   * proxy 2 seconds after creation (initialize sent after waiting for
   * confirmations is snipeable). Constructor-time initialization is not an
   * option: the init flow delegatecalls a provider which calls back
   * vault.asset(), and the proxy has no code during its own constructor.
   *
   * Countermeasure: send approve, proxy deployment and initialize as three
   * back-to-back transactions with explicit nonces, no waiting in between.
   * On FCFS chains nothing can be ordered between them.
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
    const [deployerSigner] = await ethers.getSigners();
    const startNonce = await deployerSigner.getNonce();
    const predictedProxy = ethers.getCreateAddress({
      from: deployerSigner.address,
      nonce: startNonce + 1,
    });

    const usdcInstance = await ethers.getContractAt('IERC20', usdcAddress);
    const tupArtifact =
      await hre.artifacts.readArtifact('TransparentUpgradeableProxy');
    const proxyFactory = new ethers.ContractFactory(
      tupArtifact.abi,
      tupArtifact.bytecode,
      deployerSigner,
    );
    const proxyDeployTx = await proxyFactory.getDeployTransaction(
      implementation.address,
      TREASURY_ADDRESS,
      '0x', // constructor must NOT initialize: the provider delegatecall
      // inside initialize calls back vault.asset(), which fails while the
      // proxy constructor is still running (no code yet). Init is tx3.
    );

    const approveTx = await usdcInstance.approve.populateTransaction(
      predictedProxy,
      minAssets,
    );

    // fire all three without waiting in between
    const tx1 = await deployerSigner.sendTransaction({
      ...approveTx,
      nonce: startNonce,
      gasLimit: 200_000n,
    });
    const tx2 = await deployerSigner.sendTransaction({
      ...proxyDeployTx,
      nonce: startNonce + 1,
      gasLimit: 4_000_000n,
    });
    const tx3 = await deployerSigner.sendTransaction({
      to: predictedProxy,
      data: initCalldata,
      nonce: startNonce + 2,
      gasLimit: 2_000_000n,
    });

    log('----------------------------------------------------');
    log(
      `Proxy pipeline sent: approve ${tx1.hash} deploy ${tx2.hash} init ${tx3.hash}`,
    );

    const [r1, r2, r3] = await Promise.all([
      tx1.wait(waitConfirmations),
      tx2.wait(waitConfirmations),
      tx3.wait(waitConfirmations),
    ]);
    if (!r1 || r1.status !== 1) {
      throw new Error('approve tx failed');
    }
    if (!r2 || r2.status !== 1) {
      throw new Error('proxy deploy tx failed');
    }
    if (!r3 || r3.status !== 1) {
      throw new Error('initialize tx failed');
    }

    // sanity: our initialize must have won (no sniper got in between)
    const postInit = new ethers.Contract(
      predictedProxy,
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
        `Proxy ${predictedProxy} was initialized by someone else — not recording it`,
      );
    }
    if (
      r2.contractAddress &&
      r2.contractAddress.toLowerCase() !== predictedProxy.toLowerCase()
    ) {
      throw new Error(
        `Predicted proxy address mismatch: predicted ${predictedProxy}, got ${r2.contractAddress}`,
      );
    }
    proxyAddress = predictedProxy;

    // persist a hardhat-deploy record so reruns/verifications work
    const fs = await import('fs');
    const path = await import('path');
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
          transactionHash: r2.hash,
          receipt: r2,
        },
        null,
        2,
      ),
    );

    log('----------------------------------------------------');
    log(`Proxy at ${proxyAddress} (initialized in the same pipeline)`);
  }

  if (isLive) {
    await verify(implementation.address, []);
    await verify(proxyAddress, [implementation.address, TREASURY_ADDRESS, '0x']);
  }
};

export default deployUsdcVault;
deployUsdcVault.tags = ['all', 'usdc-vault'];
