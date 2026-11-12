const fs = require('fs');
const path = require('path');
const { TronWeb } = require('tronweb');

const ROOT = path.resolve(__dirname, '..');
const ZERO_BYTES32 = `0x${'0'.repeat(64)}`;

const MAINNET_DEFAULTS = {
  fullHost: 'https://api.trongrid.io',
  dmpGate: 'TTGA4XQ419jodtFSMFiwYqfgG2uSLRBsnn',
  dlnSource: 'TX2Ut1reF59i2WPzsYVoMfA25EkUkavnd5',
  payoutExecutor: 'TJuJ19AsSBahPvg2j5AS3v37TtnmuMmeDL',
  usdt: 'TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj',
};

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function integerEnv(name, fallback, min, max) {
  const raw = process.env[name] || fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return value;
}

function evmBytes32(name, value) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error(`${name} must be a 20-byte EVM address`);
  }
  return `0x${value.slice(2).toLowerCase().padStart(64, '0')}`;
}

function tronHex20(tronWeb, address) {
  if (!tronWeb.isAddress(address)) throw new Error(`Invalid TRON address: ${address}`);
  const hex = tronWeb.address.toHex(address).replace(/^0x/, '').toLowerCase();
  if (!/^41[0-9a-f]{40}$/.test(hex)) {
    throw new Error(`Unexpected TRON address encoding: ${address}`);
  }
  return `0x${hex.slice(2)}`;
}

function sameTronAddress(tronWeb, left, right) {
  return tronWeb.address.toHex(left).toLowerCase() === tronWeb.address.toHex(right).toLowerCase();
}

function artifact(name) {
  const file = path.join(ROOT, 'build', 'tron-contracts', `${name}.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`Missing ${file}; run npm run compile:tron first`);
  }
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function manifestPath(network) {
  return path.join(ROOT, 'deployments', 'tron', `${network}-deployment.json`);
}

function loadManifest(network) {
  const file = process.env.TRON_DEPLOYMENT_MANIFEST || manifestPath(network);
  if (!fs.existsSync(file)) throw new Error(`TRON deployment manifest not found: ${file}`);
  return { file, data: JSON.parse(fs.readFileSync(file, 'utf8')) };
}

function writeManifest(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function deploymentConfig() {
  const network = process.env.TRON_NETWORK || 'nile';
  if (!['mainnet', 'nile'].includes(network)) {
    throw new Error('TRON_NETWORK must be mainnet or nile');
  }

  const defaults = network === 'mainnet' ? MAINNET_DEFAULTS : {};
  const privateKey = required('TRON_DEPLOYER_PRIVATE_KEY').replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{64}$/.test(privateKey) || /^([0-9a-fA-F])\1{63}$/.test(privateKey)) {
    throw new Error('TRON_DEPLOYER_PRIVATE_KEY is invalid or a placeholder');
  }

  const fullHost = process.env.TRON_FULL_HOST || defaults.fullHost || required('TRON_FULL_HOST');
  const tronWeb = new TronWeb({
    fullHost,
    privateKey,
    headers: process.env.TRONGRID_API_KEY
      ? { 'TRON-PRO-API-KEY': process.env.TRONGRID_API_KEY }
      : undefined,
  });

  const config = {
    network,
    fullHost,
    privateKey,
    tronWeb,
    deployer: tronWeb.defaultAddress.base58,
    dmpGate: process.env.TRON_DEBRIDGE_GATE || defaults.dmpGate || required('TRON_DEBRIDGE_GATE'),
    dlnSource: process.env.TRON_DLN_SOURCE || defaults.dlnSource || required('TRON_DLN_SOURCE'),
    payoutExecutor:
      process.env.TRON_PAYOUT_EXECUTOR || defaults.payoutExecutor || required('TRON_PAYOUT_EXECUTOR'),
    usdt:
      process.env.TRON_USDT_CONTRACT || defaults.usdt || required('TRON_USDT_CONTRACT'),
    baseChain: integerEnv('DEBRIDGE_BASE_CHAIN_ID', '8453', 1, 0xffffffff),
    baseUsdc: process.env.BASE_USDC || '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    hookGas: integerEnv('BASE_DEPOSIT_HOOK_GAS', '1000000', 1, 0xffffffff),
    referralCode: integerEnv('DEBRIDGE_REFERRAL_CODE', '0', 0, 0xffffffff),
    feeLimit: integerEnv('TRON_FEE_LIMIT', '1000000000', 1, 15000000000),
    originEnergyLimit: integerEnv(
      'TRON_ORIGIN_ENERGY_LIMIT',
      '10000000',
      1,
      100000000
    ),
    userFeePercentage: integerEnv('TRON_USER_FEE_PERCENTAGE', '100', 1, 100),
  };

  for (const address of [
    config.deployer,
    config.dmpGate,
    config.dlnSource,
    config.payoutExecutor,
    config.usdt,
  ]) {
    if (!tronWeb.isAddress(address)) throw new Error(`Invalid TRON address: ${address}`);
  }
  evmBytes32('BASE_USDC', config.baseUsdc);
  return config;
}

async function requireContract(tronWeb, name, address) {
  try {
    const contract = await tronWeb.trx.getContract(address);
    if (!contract || !contract.bytecode) throw new Error('empty bytecode');
  } catch (error) {
    throw new Error(`${name} has no contract bytecode at ${address}: ${error.message}`);
  }
}

async function send(contractMethod, feeLimit) {
  return contractMethod.send({ feeLimit, shouldPollResponse: true });
}

module.exports = {
  ROOT,
  ZERO_BYTES32,
  artifact,
  deploymentConfig,
  evmBytes32,
  loadManifest,
  manifestPath,
  requireContract,
  sameTronAddress,
  send,
  tronHex20,
  writeManifest,
};
