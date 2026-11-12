import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

import { verify } from '../utils/verify';
import {
  BASE_DEBRIDGE_DLN_SOURCE,
  BASE_DEBRIDGE_DLN_UNIVERSAL_HOOK,
  BASE_DEBRIDGE_GATE,
  BASE_USDC,
  BASE_USDC_REBALANCER,
  DEBRIDGE_TRON_CHAIN_ID,
} from '../utils/tron-connector-constants';

const BASE_CHAIN_ID = 8453n;
const ADDRESS_BYTES = 20;

function requiredAddress(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function remoteAddress(name: string, value: string): string {
  const hex = value.replace(/^0x/, '');
  if (!new RegExp(`^[0-9a-fA-F]{${ADDRESS_BYTES * 2}}$`).test(hex)) {
    throw new Error(`${name} must be a 20-byte TVM hex address`);
  }
  return `0x${hex.toLowerCase().padStart(64, '0')}`;
}

const deployBaseTronConnector: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, ethers, getNamedAccounts } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const network = await ethers.provider.getNetwork();

  if (network.chainId !== BASE_CHAIN_ID) {
    throw new Error(`Base deployment only: expected chain 8453, got ${network.chainId}`);
  }

  const owner = process.env.BASE_CONNECTOR_OWNER || requiredAddress('TREASURY_ADDRESS');
  const vault = process.env.BASE_REBALANCER || BASE_USDC_REBALANCER;
  const depositExecutor =
    process.env.BASE_DEPOSIT_EXECUTOR || BASE_DEBRIDGE_DLN_UNIVERSAL_HOOK;
  const tronGateway = remoteAddress(
    'TRON_GATEWAY_ADDRESS',
    requiredAddress('TRON_GATEWAY_ADDRESS'),
  );
  const tronUsdt = remoteAddress(
    'TRON_USDT_ADDRESS',
    requiredAddress('TRON_USDT_ADDRESS'),
  );
  const tronMessenger = remoteAddress(
    'TRON_MESSENGER_ADAPTER',
    requiredAddress('TRON_MESSENGER_ADAPTER'),
  );
  const hookGas = Number(process.env.TRON_WITHDRAWAL_HOOK_GAS || '1000000');
  const referralCode = Number(process.env.DEBRIDGE_REFERRAL_CODE || '0');

  if (!Number.isSafeInteger(hookGas) || hookGas <= 0 || hookGas > 0xffffffff) {
    throw new Error(`Invalid TRON_WITHDRAWAL_HOOK_GAS: ${hookGas}`);
  }
  if (
    !Number.isSafeInteger(referralCode) ||
    referralCode < 0 ||
    referralCode > 0xffffffff
  ) {
    throw new Error(`Invalid DEBRIDGE_REFERRAL_CODE: ${referralCode}`);
  }

  for (const [name, address] of [
    ['vault', vault],
    ['deposit executor', depositExecutor],
    ['DLN source', BASE_DEBRIDGE_DLN_SOURCE],
    ['deBridge gate', BASE_DEBRIDGE_GATE],
  ] as const) {
    if (!(await ethers.isAddress(address))) throw new Error(`Invalid ${name}: ${address}`);
    if ((await ethers.provider.getCode(address)) === '0x') {
      throw new Error(`No Base bytecode at ${name} ${address}`);
    }
  }

  if (!(await ethers.isAddress(owner)) || owner === ethers.ZeroAddress) {
    throw new Error(`Invalid connector owner: ${owner}`);
  }

  const vaultContract = await ethers.getContractAt(
    ['function asset() view returns (address)', 'function decimals() view returns (uint8)'],
    vault,
  );
  const asset = await vaultContract.asset();
  if (asset.toLowerCase() !== BASE_USDC.toLowerCase()) {
    throw new Error(`Vault asset ${asset} is not native Base USDC ${BASE_USDC}`);
  }
  if ((await vaultContract.decimals()) !== 6n) {
    throw new Error('Base Rebalancer shares must use 6 decimals');
  }

  const messengerArgs = [
    owner,
    BASE_DEBRIDGE_GATE,
    DEBRIDGE_TRON_CHAIN_ID,
    tronMessenger,
  ];
  const messengerDeployment = await deploy('BaseDeBridgeMessengerAdapter', {
    contract: 'DeBridgeMessengerAdapter',
    from: deployer,
    args: messengerArgs,
    log: true,
    waitConfirmations: 2,
  });

  const bridgeArgs = [
    deployer,
    BASE_DEBRIDGE_DLN_SOURCE,
    BASE_USDC,
    DEBRIDGE_TRON_CHAIN_ID,
    tronUsdt,
    tronGateway,
    hookGas,
    referralCode,
  ];
  const bridgeDeployment = await deploy('BaseDlnAssetBridge', {
    from: deployer,
    args: bridgeArgs,
    log: true,
    waitConfirmations: 2,
  });

  const args = [
    owner,
    vault,
    depositExecutor,
    bridgeDeployment.address,
    messengerDeployment.address,
    DEBRIDGE_TRON_CHAIN_ID,
    tronGateway,
  ];

  log('Deploying BaseTronConnector against the existing Base USDC Rebalancer...');
  const deployment = await deploy('BaseTronConnector', {
    contract: 'EvmTronConnector',
    from: deployer,
    args,
    log: true,
    waitConfirmations: 2,
  });

  log(`BaseTronConnector: ${deployment.address}`);
  log(`Owner: ${owner}`);
  log(`Vault: ${vault}`);
  log(`Inbound DLN executor: ${depositExecutor}`);
  log(`Outbound bridge adapter: ${bridgeDeployment.address}`);
  log(`Messenger adapter: ${messengerDeployment.address}`);
  log(`TRON gateway: ${tronGateway}`);

  const signer = await ethers.getSigner(deployer);
  const bridge = await ethers.getContractAt(
    'BaseDlnAssetBridge',
    bridgeDeployment.address,
    signer,
  );
  const configuredConnector = await bridge.connector();
  if (configuredConnector === ethers.ZeroAddress) {
    await (await bridge.setConnector(deployment.address)).wait();
  } else if (configuredConnector.toLowerCase() !== deployment.address.toLowerCase()) {
    throw new Error(`Bridge is already bound to ${configuredConnector}`);
  }

  const bridgeOwner = await bridge.owner();
  if (
    bridgeOwner.toLowerCase() === deployer.toLowerCase() &&
    owner.toLowerCase() !== deployer.toLowerCase()
  ) {
    await (await bridge.transferOwnership(owner)).wait();
  }

  if (process.env.SKIP_VERIFY !== 'true') {
    if (messengerDeployment.newlyDeployed) {
      await verify(messengerDeployment.address, messengerArgs);
    }
    if (bridgeDeployment.newlyDeployed) {
      await verify(bridgeDeployment.address, bridgeArgs);
    }
  }
  if (deployment.newlyDeployed && process.env.SKIP_VERIFY !== 'true') {
    await verify(deployment.address, args);
  }
};

export default deployBaseTronConnector;
deployBaseTronConnector.tags = ['base-tron-connector'];
