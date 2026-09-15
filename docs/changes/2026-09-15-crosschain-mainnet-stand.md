# Changes: 2026-09-15 — Mainnet Crosschain Stand Deployment

**Branch:** `crosschain-sandbox`
**Date:** 2026-09-15
**Author:** cto-agent

## Summary

Mainnet deployment infrastructure for a SEPARATE crosschain stand. Does NOT
touch existing production vaults. Deploys MeshNode (source, Base) and
MeshCustodian (destination, Arbitrum) with Timelock governance.

## New Files

- `scripts/DeployCrosschainStand.s.sol` — Foundry deploy script
- `test/forking/CrosschainStandFork.t.sol` — Fork tests (Base + Arbitrum)
- `scripts/canary-cycle.ts` — Canary flow checklist script

## Architecture

```
Base (source)                    Arbitrum (destination)
┌─────────────────────┐          ┌─────────────────────┐
│ MeshNode            │          │ MeshCustodian       │
│  governance: Timelock│          │  governance: Timelock│
│  executor: keeper   │    ───>  │  executor: keeper   │
│  guardian: guardian │  bridge  │  guardian: guardian │
│                     │          │                     │
│ MeshProvider        │          │ ICustodianProvider  │
│  (vault integration)│          │  (yield deployment) │
└─────────────────────┘          └─────────────────────┘
```

## Deployment Steps

### 1. Pre-deploy: Fork verification

```bash
# Base fork — verifies MeshNode + MeshProvider
forge test --match-contract CrosschainStandForkTest \
  --fork-url $BASE_RPC_URL -vv

# Arbitrum fork — verifies MeshCustodian
forge test --match-contract CrosschainStandForkTestArbitrum \
  --fork-url $ARBITRUM_RPC_URL -vv
```

### 2. Deploy source (Base)

```bash
export DEPLOY_SIDE=source
export KEEPER=0x48aee41F80B8E7b3c5a1B3c5d7f2e9a1b3c5d7f2  # existing keeper
export GUARDIAN=0x...  # emergency pause address
export ASSET_BASE=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

forge script scripts/DeployCrosschainStand.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

### 3. Deploy destination (Arbitrum)

```bash
export DEPLOY_SIDE=destination
export ASSET_ARBITRUM=0xaf88d065e77c8cC2239327C5EDb3A432268e5831

forge script scripts/DeployCrosschainStand.s.sol \
  --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
```

### 4. Post-deploy configuration

```
# On Base (source):
node.configureVault(vaultAddr, true, 2000, 8000)
node.addRoute(routeId, bridgeAdapter, 42161, custodianPeer, maxInFlight, maxFeeBps)
node.setGovernance(timelockAddr)

# On Arbitrum (destination):
custodian.trustAdapter(bridgeAdapter, true)
custodian.allowProvider(custodianProvider, true)
custodian.setGovernance(timelockAddr)
```

### 5. Canary flow

```bash
export MESH_NODE_BASE=0x...
export MESH_CUSTODIAN_ARB=0x...
export BRIDGE_ADAPTER_BASE=0x...
export CANARY_AMOUNT=10000000  # $10 USDC

npx hardhat run scripts/canary-cycle.ts --network base
```

## Fork Test Results

```
Base fork (https://mainnet.base.org):
  CrosschainStandForkTest: 6 passed, 0 failed
  CrosschainStandForkTestArbitrum: 1 skipped (correct — not on Arbitrum)

Arbitrum fork (https://arb1.arbitrum.io/rpc):
  CrosschainStandForkTestArbitrum: 5 passed, 0 failed
```

## Safety Guarantees

- Existing vaults NOT modified (no setProviders, no rebalance calls)
- New contracts deployed at fresh addresses
- Governance starts as deployer, transferred to Timelock post-config
- Guardian can pause immediately; only Timelock can unpause
- All operations require executor (keeper) role
- Bridge adapter must be explicitly trusted by governance
- Providers must be explicitly allowed by governance

## Next Steps

1. Deploy bridge adapter (authenticated — Stargate/LayerZero/CCTP)
2. Execute canary with $10 USDC
3. Verify full cycle accounting on both chains
4. Gradually increase canary amount ($100, $1000, $10k)
5. After successful canary: configure existing vault to use MeshProvider
