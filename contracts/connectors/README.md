# TRON Connector

This module mirrors EVM vault shares as transferable TRC20 `tUSDT`.

## Contracts

- `TronGateway`: accepts TRON USDT deposits, escrows `tUSDT` redemptions, and pays returned USDT.
- `TronTUSDT`: share representation minted and burned only by `TronGateway`.
- `EvmTronConnector`: deposits bridged assets into `Rebalancer`, holds the backing shares, and redeems them for withdrawals.
- `ConnectorCodec`: versioned deposit, acknowledgement, redeem, and withdrawal payloads.

The connector is intentionally not an `IProvider`. It interacts with `Rebalancer` as a regular depositor and share holder.

## Transport adapters

Inbound delivery and outbound order creation are deliberately separate: `depositExecutor`/`payoutExecutor` authenticate destination delivery, while `assetBridge` creates source orders. The Base deployment uses `BaseDlnAssetBridge` for outbound USDC orders and `DeBridgeMessengerAdapter` for authenticated DMP messages.

An asset bridge adapter must:

1. Pull the exact approved source amount during `bridgeAsset`.
2. Authenticate the source transfer and preserve the original payload.
3. Approve and call `receiveBridgedDeposit` or `receiveBridgedWithdrawal` with the delivered balance delta.
4. Call `receiveBridgedDepositRefund` only after proving the destination transfer cannot settle.

A messenger adapter must pass the verified source chain and source connector to `receiveMessage`. A relayer address alone is not sufficient authentication.

## Deployment

The deployment uses one-time pairing instead of nonce-based address prediction. `TronGateway.evmConnector` and the TRON messenger's `remoteAdapter` start unset, cannot process user requests, and are permanently bound after the Base contracts exist. Owners should be timelock-controlled multisigs.

TRON contracts compile with the TRON Solidity 0.8.24 compiler:

```bash
npm run compile:tron
```

Before mainnet, run a Nile-to-Base end-to-end test, set transport limits, and audit the complete deployment configuration.

### Staged deployment

1. Fill the TRON variables in `.env` and deploy the TRON contracts:

```bash
npm run deploy:tron-connector
```

This uses the TRON Solidity 0.8.24 compiler, checks protocol bytecode and USDT decimals, then deploys:

- `DeBridgeMessengerAdapter` (initially unpaired);
- `TronDlnAssetBridge` and binds it to the gateway;
- `TronGateway`, which creates `TronTUSDT` in its constructor.

The resulting manifest is stored in `deployments/tron/<network>-deployment.json`. Copy its `baseEnv` values to `.env`.

2. Deploy the Base side:

```bash
npm run deploy:base-tron-connector
```

3. Bind the Base connector and messenger on TRON and transfer/propose ownership to `TRON_CONNECTOR_OWNER`:

```bash
npm run configure:tron-connector
```

If `TronGateway` ownership is proposed to a multisig, that multisig must finish the two-step transfer by calling `acceptOwnership()`.

## Base deployment

The repository is pinned to native Base USDC and the deployed Thesauros USDC Rebalancer. The default inbound executor is the deBridge Universal DLN Hook on Base. The deployment creates the Base DLN asset adapter and DMP messenger adapter before deploying and binding the connector.

```bash
npm run deploy:base-tron-connector
```

The script refuses non-Base networks and checks the vault asset, share decimals, and bytecode at every transport address before broadcasting the deployment.

If an outbound Base DLN order is cancelled, its USDC cancellation beneficiary is the Base connector. After the refund is finalized on Base, the connector owner can call `retryRedeemBridge(requestId)` with the current DLN fixed native fee to recreate the order.
