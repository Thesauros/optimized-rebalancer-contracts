#!/usr/bin/env bash
# =============================================================================
# Crosschain Stand — Full Mainnet Deployment
# =============================================================================
# Deploys MeshNode + MeshCustodian + CCTP bridge on Base and Arbitrum.
# Does NOT touch existing production vaults.
#
# Prerequisites:
#   - .env with DEPLOYER_PRIVATE_KEY, BASE_RPC_URL, ARBITRUM_RPC_URL
#   - KEEPER, GUARDIAN, RELAY_KEEPER addresses set below
#   - forge installed, contracts compiled
#
# Usage:
#   cd optimized-rebalancer-contracts
#   bash scripts/deploy/run-all.sh
#
# Phases:
#   1. Core: MeshNode (Base) + MeshCustodian (Arbitrum)
#   2. Relay: CCTPRelayReceiver on both chains
#   3. Adapter: CCTPMeshBridgeAdapter on both chains
#   4. Configure: addRoute + trustAdapter (via Timelock proposals)
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/../.."

# Load .env
set -a; source .env; set +a

# === CONFIGURE THESE ===
export KEEPER="${KEEPER:-0x48aee41F80B8E7b3c5a1B3c5d7f2e9a1b3c5d7f2}"       # executor EOA
export GUARDIAN="${GUARDIAN:-0x1234567890abcdef1234567890abcdef12345678}"       # emergency pause
export RELAY_KEEPER="${RELAY_KEEPER:-0x48aee41F80B8E7b3c5a1B3c5d7f2e9a1b3c5d7f2}" # CCTP relay keeper

# RPC URLs
BASE_RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
ARB_RPC="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"

# Etherscan keys for verification
BASESCAN_KEY="${BASESCAN_API_KEY:-$ETHERSCAN_API_KEY}"
ARBISCAN_KEY="${ARBISCAN_API_KEY:-$ETHERSCAN_API_KEY}"

echo "============================================="
echo " Crosschain Stand — Mainnet Deployment"
echo "============================================="
echo ""
echo "Base RPC:     $BASE_RPC"
echo "Arbitrum RPC: $ARB_RPC"
echo "Keeper:       $KEEPER"
echo "Guardian:     $GUARDIAN"
echo "Relay Keeper: $RELAY_KEEPER"
echo ""

# Build first
echo "[BUILD] Compiling contracts..."
forge build
echo ""

# =============================================================================
# PHASE 1: Core contracts
# =============================================================================
echo "============================================="
echo " PHASE 1: Core Contracts"
echo "============================================="

echo "[1a] Deploying MeshNode + MeshProvider on Base..."
BASE_OUT=$(forge script scripts/deploy/phase1-core-base.s.sol \
  --rpc-url "$BASE_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_KEY" \
  2>&1)
echo "$BASE_OUT"

MESH_NODE_BASE=$(echo "$BASE_OUT" | grep -oP 'MeshNode: \K0x[a-fA-F0-9]{40}' || echo "")
MESH_PROVIDER_BASE=$(echo "$BASE_OUT" | grep -oP 'MeshProvider: \K0x[a-fA-F0-9]{40}' || echo "")

if [ -z "$MESH_NODE_BASE" ]; then
  echo "ERROR: Failed to extract MeshNode address"
  echo "$BASE_OUT"
  exit 1
fi
echo "  MeshNode:     $MESH_NODE_BASE"
echo "  MeshProvider: $MESH_PROVIDER_BASE"
echo ""

echo "[1b] Deploying MeshCustodian on Arbitrum..."
ARB_OUT=$(forge script scripts/deploy/phase1-core-arbitrum.s.sol \
  --rpc-url "$ARB_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ARBISCAN_KEY" \
  2>&1)
echo "$ARB_OUT"

MESH_CUSTODIAN_ARB=$(echo "$ARB_OUT" | grep -oP 'MeshCustodian: \K0x[a-fA-F0-9]{40}' || echo "")

if [ -z "$MESH_CUSTODIAN_ARB" ]; then
  echo "ERROR: Failed to extract MeshCustodian address"
  echo "$ARB_OUT"
  exit 1
fi
echo "  MeshCustodian: $MESH_CUSTODIAN_ARB"
echo ""

# =============================================================================
# PHASE 2: Relay receivers
# =============================================================================
echo "============================================="
echo " PHASE 2: Relay Receivers"
echo "============================================="

export MESH_NODE_BASE
export MESH_CUSTODIAN_ARB

echo "[2a] Deploying CCTPRelayReceiver on Base (MODE_NODE)..."
RELAY_BASE_OUT=$(forge script scripts/deploy/phase2-relay-base.s.sol \
  --rpc-url "$BASE_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_KEY" \
  2>&1)
echo "$RELAY_BASE_OUT"

RELAY_BASE=$(echo "$RELAY_BASE_OUT" | grep -oP 'CCTPRelayReceiver: \K0x[a-fA-F0-9]{40}' || echo "")
if [ -z "$RELAY_BASE" ]; then
  echo "ERROR: Failed to extract Base relay address"
  exit 1
fi
echo "  Relay (Base): $RELAY_BASE"
echo ""

echo "[2b] Deploying CCTPRelayReceiver on Arbitrum (MODE_CUSTODIAN)..."
RELAY_ARB_OUT=$(forge script scripts/deploy/phase2-relay-arbitrum.s.sol \
  --rpc-url "$ARB_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ARBISCAN_KEY" \
  2>&1)
echo "$RELAY_ARB_OUT"

RELAY_ARB=$(echo "$RELAY_ARB_OUT" | grep -oP 'CCTPRelayReceiver: \K0x[a-fA-F0-9]{40}' || echo "")
if [ -z "$RELAY_ARB" ]; then
  echo "ERROR: Failed to extract Arbitrum relay address"
  exit 1
fi
echo "  Relay (Arbitrum): $RELAY_ARB"
echo ""

# =============================================================================
# PHASE 3: Bridge adapters
# =============================================================================
echo "============================================="
echo " PHASE 3: Bridge Adapters"
echo "============================================="

export RELAY_BASE
export RELAY_ARB

echo "[3a] Deploying CCTPMeshBridgeAdapter on Base..."
ADAPTER_BASE_OUT=$(forge script scripts/deploy/phase3-adapter-base.s.sol \
  --rpc-url "$BASE_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$BASESCAN_KEY" \
  2>&1)
echo "$ADAPTER_BASE_OUT"

ADAPTER_BASE=$(echo "$ADAPTER_BASE_OUT" | grep -oP 'CCTPMeshBridgeAdapter: \K0x[a-fA-F0-9]{40}' || echo "")
if [ -z "$ADAPTER_BASE" ]; then
  echo "ERROR: Failed to extract Base adapter address"
  exit 1
fi
echo "  Adapter (Base): $ADAPTER_BASE"
echo ""

echo "[3b] Deploying CCTPMeshBridgeAdapter on Arbitrum..."
ADAPTER_ARB_OUT=$(forge script scripts/deploy/phase3-adapter-arbitrum.s.sol \
  --rpc-url "$ARB_RPC" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ARBISCAN_KEY" \
  2>&1)
echo "$ADAPTER_ARB_OUT"

ADAPTER_ARB=$(echo "$ADAPTER_ARB_OUT" | grep -oP 'CCTPMeshBridgeAdapter: \K0x[a-fA-F0-9]{40}' || echo "")
if [ -z "$ADAPTER_ARB" ]; then
  echo "ERROR: Failed to extract Arbitrum adapter address"
  exit 1
fi
echo "  Adapter (Arbitrum): $ADAPTER_ARB"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "============================================="
echo " DEPLOYMENT COMPLETE"
echo "============================================="
echo ""
echo "Base (source, domain 6):"
echo "  MeshNode:              $MESH_NODE_BASE"
echo "  MeshProvider:          $MESH_PROVIDER_BASE"
echo "  CCTPRelayReceiver:     $RELAY_BASE  (MODE_NODE)"
echo "  CCTPMeshBridgeAdapter: $ADAPTER_BASE"
echo ""
echo "Arbitrum (destination, domain 3):"
echo "  MeshCustodian:         $MESH_CUSTODIAN_ARB"
echo "  CCTPRelayReceiver:     $RELAY_ARB  (MODE_CUSTODIAN)"
echo "  CCTPMeshBridgeAdapter: $ADAPTER_ARB"
echo ""
echo "============================================="
echo " NEXT: Run configuration"
echo "============================================="
echo ""
echo "  bash scripts/deploy/configure.sh"
echo ""
echo "Then start the relay keeper:"
echo ""
echo "  # Terminal 1 (Base -> Arbitrum relay):"
echo "  CCTP_ADAPTER_SOURCE=$ADAPTER_BASE \\"
echo "  CCTP_RELAY_DEST=$RELAY_ARB \\"
echo "  CCTP_DEST_RPC=$ARB_RPC \\"
echo "  CCTP_SOURCE_DOMAIN=6 CCTP_DEST_DOMAIN=3 \\"
echo "  npx hardhat run scripts/cctp-relay-keeper.ts --network base"
echo ""
echo "  # Terminal 2 (Arbitrum -> Base relay):"
echo "  CCTP_ADAPTER_SOURCE=$ADAPTER_ARB \\"
echo "  CCTP_RELAY_DEST=$RELAY_BASE \\"
echo "  CCTP_DEST_RPC=$BASE_RPC \\"
echo "  CCTP_SOURCE_DOMAIN=3 CCTP_DEST_DOMAIN=6 \\"
echo "  npx hardhat run scripts/cctp-relay-keeper.ts --network arbitrum"
echo ""

# Save addresses for configure.sh
cat > scripts/deploy/.deployed-addresses <<EOF
MESH_NODE_BASE=$MESH_NODE_BASE
MESH_PROVIDER_BASE=$MESH_PROVIDER_BASE
MESH_CUSTODIAN_ARB=$MESH_CUSTODIAN_ARB
RELAY_BASE=$RELAY_BASE
RELAY_ARB=$RELAY_ARB
ADAPTER_BASE=$ADAPTER_BASE
ADAPTER_ARB=$ADAPTER_ARB
EOF
echo "Addresses saved to scripts/deploy/.deployed-addresses"
