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

The remote connector addresses are immutable. Predict both deployment addresses, or deploy them deterministically with `CREATE2`, before constructing the pair. Owners should be timelock-controlled multisigs.

TRON contracts compile with Solidity 0.8.20:

```bash
forge build contracts/connectors/TronGateway.sol contracts/connectors/TronTUSDT.sol --use 0.8.20
```

Before mainnet, add the selected bridge adapters, run a Nile-to-EVM end-to-end test, set transport limits, and audit the complete deployment configuration.

## Base deployment

The repository is pinned to native Base USDC and the deployed Thesauros USDC Rebalancer. The default inbound executor is the deBridge Universal DLN Hook on Base. The deployment creates the Base DLN asset adapter and DMP messenger adapter before deploying and binding the connector.

```bash
npm run deploy:base-tron-connector
```

The script refuses non-Base networks and checks the vault asset, share decimals, and bytecode at every transport address before broadcasting the deployment.

If an outbound Base DLN order is cancelled, its USDC cancellation beneficiary is the Base connector. After the refund is finalized on Base, the connector owner can call `retryRedeemBridge(requestId)` with the current DLN fixed native fee to recreate the order.
