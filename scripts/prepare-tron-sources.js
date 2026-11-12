const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const sourceRoot = path.join(root, 'contracts', 'connectors');
const destinationRoot = path.join(root, '.tron-contracts');
const sources = [
  'DeBridgeMessengerAdapter.sol',
  'TronDlnAssetBridge.sol',
  'TronGateway.sol',
  'TronTUSDT.sol',
  'interfaces/IAssetBridge.sol',
  'interfaces/ICrossChainMessenger.sol',
  'interfaces/IDeBridgeCallProxy.sol',
  'interfaces/IDeBridgeGate.sol',
  'interfaces/IDlnSource.sol',
  'libraries/ConnectorCodec.sol',
];

fs.rmSync(destinationRoot, { recursive: true, force: true });
for (const relative of sources) {
  const source = path.join(sourceRoot, relative);
  const destination = path.join(destinationRoot, relative);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

