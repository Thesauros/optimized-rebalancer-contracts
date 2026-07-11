require('dotenv').config();

const fs = require('fs');
const path = require('path');
const {
  ZERO_BYTES32,
  artifact,
  deploymentConfig,
  evmBytes32,
  loadManifest,
  sameTronAddress,
  send,
  writeManifest,
} = require('./tron-deployment-common');

function baseDeploymentAddress(envName, deploymentName) {
  if (process.env[envName]) return process.env[envName];
  const file = path.resolve(__dirname, '..', 'deployments', 'base', `${deploymentName}.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`${envName} is required because ${file} does not exist`);
  }
  return JSON.parse(fs.readFileSync(file, 'utf8')).address;
}

async function setOnce(current, expected, method, feeLimit, label) {
  if (String(current).toLowerCase() === ZERO_BYTES32.toLowerCase()) {
    await send(method, feeLimit);
    console.log(`${label}: configured`);
    return;
  }
  if (String(current).toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${label} is already bound to ${current}, expected ${expected}`);
  }
  console.log(`${label}: already configured`);
}

async function main() {
  const config = deploymentConfig();
  const { file, data } = loadManifest(config.network);
  const baseConnector = baseDeploymentAddress(
    'BASE_CONNECTOR_ADDRESS',
    'BaseTronConnector'
  );
  const baseMessenger = baseDeploymentAddress(
    'BASE_MESSENGER_ADAPTER_ADDRESS',
    'BaseDeBridgeMessengerAdapter'
  );
  const connectorBytes = evmBytes32('BASE_CONNECTOR_ADDRESS', baseConnector);
  const messengerBytes = evmBytes32('BASE_MESSENGER_ADAPTER_ADDRESS', baseMessenger);

  const gateway = await config.tronWeb.contract(
    artifact('TronGateway').abi,
    data.contracts.gateway
  );
  const messenger = await config.tronWeb.contract(
    artifact('DeBridgeMessengerAdapter').abi,
    data.contracts.messengerAdapter
  );
  const bridge = await config.tronWeb.contract(
    artifact('TronDlnAssetBridge').abi,
    data.contracts.assetBridge
  );

  await setOnce(
    await gateway.evmConnector().call(),
    connectorBytes,
    gateway.setEvmConnector(connectorBytes),
    config.feeLimit,
    'TronGateway.evmConnector'
  );
  await setOnce(
    await messenger.remoteAdapter().call(),
    messengerBytes,
    messenger.setRemoteAdapter(messengerBytes),
    config.feeLimit,
    'TRON messenger.remoteAdapter'
  );

  const intendedOwner = data.intendedOwner || config.deployer;
  if (!sameTronAddress(config.tronWeb, intendedOwner, config.deployer)) {
    const messengerOwner = await messenger.owner().call();
    if (sameTronAddress(config.tronWeb, messengerOwner, config.deployer)) {
      await send(messenger.transferOwnership(intendedOwner), config.feeLimit);
      console.log(`Messenger ownership transferred to ${intendedOwner}`);
    }
    const bridgeOwner = await bridge.owner().call();
    if (sameTronAddress(config.tronWeb, bridgeOwner, config.deployer)) {
      await send(bridge.transferOwnership(intendedOwner), config.feeLimit);
      console.log(`Bridge ownership transferred to ${intendedOwner}`);
    }
    const gatewayOwner = await gateway.owner().call();
    if (sameTronAddress(config.tronWeb, gatewayOwner, config.deployer)) {
      await send(gateway.transferOwnership(intendedOwner), config.feeLimit);
      console.log(`Gateway ownership proposed to ${intendedOwner}; it must call acceptOwnership()`);
    }
  }

  data.pairing = {
    baseConnector,
    baseMessengerAdapter: baseMessenger,
    completed: true,
    configuredAt: new Date().toISOString(),
  };
  writeManifest(file, data);
  console.log(`Pairing complete. Manifest updated: ${file}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});

