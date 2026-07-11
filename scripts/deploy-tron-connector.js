require('dotenv').config();

const {
  ZERO_BYTES32,
  artifact,
  deploymentConfig,
  evmBytes32,
  manifestPath,
  requireContract,
  send,
  tronHex20,
  writeManifest,
} = require('./tron-deployment-common');

async function deploy(tronWeb, config, name, parameters) {
  const compiled = artifact(name);
  const instance = await tronWeb.contract().new({
    abi: compiled.abi,
    bytecode: compiled.bytecode.replace(/^0x/, ''),
    feeLimit: config.feeLimit,
    callValue: 0,
    userFeePercentage: config.userFeePercentage,
    originEnergyLimit: config.originEnergyLimit,
    parameters,
  });
  if (!instance.address) throw new Error(`${name} deployment returned no address`);
  console.log(`${name}: ${instance.address}`);
  return instance;
}

async function main() {
  const config = deploymentConfig();
  const output = manifestPath(config.network);
  const fs = require('fs');
  if (fs.existsSync(output) && process.env.TRON_ALLOW_REDEPLOY !== 'true') {
    throw new Error(
      `${output} already exists; set TRON_ALLOW_REDEPLOY=true only for an intentional redeploy`
    );
  }

  console.log(`TRON network: ${config.network}`);
  console.log(`Deployer: ${config.deployer}`);
  await requireContract(config.tronWeb, 'deBridge DMP gate', config.dmpGate);
  await requireContract(config.tronWeb, 'DLN source', config.dlnSource);
  await requireContract(config.tronWeb, 'DLN universal hook', config.payoutExecutor);
  await requireContract(config.tronWeb, 'USDT', config.usdt);

  const usdt = await config.tronWeb.contract(
    [{ constant: true, inputs: [], name: 'decimals', outputs: [{ type: 'uint8' }], type: 'function' }],
    config.usdt
  );
  const decimals = Number(await usdt.decimals().call());
  if (decimals !== 6) throw new Error(`TRON USDT must use 6 decimals, got ${decimals}`);

  const messenger = await deploy(config.tronWeb, config, 'DeBridgeMessengerAdapter', [
    config.deployer,
    config.dmpGate,
    config.baseChain,
    ZERO_BYTES32,
  ]);
  const bridge = await deploy(config.tronWeb, config, 'TronDlnAssetBridge', [
    config.deployer,
    config.dlnSource,
    config.usdt,
    config.baseChain,
    evmBytes32('BASE_USDC', config.baseUsdc),
    config.hookGas,
    config.referralCode,
  ]);
  const gateway = await deploy(config.tronWeb, config, 'TronGateway', [
    config.deployer,
    config.usdt,
    config.payoutExecutor,
    bridge.address,
    messenger.address,
    config.baseChain,
    ZERO_BYTES32,
  ]);

  await send(bridge.setConnector(gateway.address), config.feeLimit);
  const tUsdt = await gateway.tUSDT().call();
  const finalOwner = process.env.TRON_CONNECTOR_OWNER || config.deployer;
  if (!config.tronWeb.isAddress(finalOwner)) {
    throw new Error(`Invalid TRON_CONNECTOR_OWNER: ${finalOwner}`);
  }

  const manifest = {
    network: config.network,
    deployedAt: new Date().toISOString(),
    deployer: config.deployer,
    intendedOwner: finalOwner,
    contracts: {
      messengerAdapter: messenger.address,
      assetBridge: bridge.address,
      gateway: gateway.address,
      tUsdt,
    },
    baseEnv: {
      TRON_MESSENGER_ADAPTER: tronHex20(config.tronWeb, messenger.address),
      TRON_GATEWAY_ADDRESS: tronHex20(config.tronWeb, gateway.address),
      TRON_USDT_ADDRESS: tronHex20(config.tronWeb, config.usdt),
    },
    protocol: {
      dmpGate: config.dmpGate,
      dlnSource: config.dlnSource,
      payoutExecutor: config.payoutExecutor,
      baseChain: config.baseChain,
      baseUsdc: config.baseUsdc,
      hookGas: config.hookGas,
      referralCode: config.referralCode,
    },
    pairing: {
      baseConnector: null,
      baseMessengerAdapter: null,
      completed: false,
    },
  };
  writeManifest(output, manifest);

  console.log(`tUSDT: ${tUsdt}`);
  console.log(`Manifest: ${output}`);
  console.log('Next: copy baseEnv values to .env and run npm run deploy:base-tron-connector');
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});

