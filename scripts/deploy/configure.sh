#!/usr/bin/env bash
# =============================================================================
# Crosschain Stand — Post-Deploy Configuration
# =============================================================================
# Configures routes and trust after deployment. All governance actions go
# through the Timelock (queue + execute).
#
# Prerequisites:
#   - scripts/deploy/.deployed-addresses exists (from run-all.sh)
#   - .env with DEPLOYER_PRIVATE_KEY, RPC URLs
#
# Usage:
#   bash scripts/deploy/configure.sh
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/../.."

set -a; source .env; set +a
source scripts/deploy/.deployed-addresses

BASE_RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
ARB_RPC="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"

# Route parameters
ROUTE_ID="0x$(echo -n 'base-arb-cctp' | sha256sum | cut -d' ' -f1)"
MAX_IN_FLIGHT="1000000000000"  # 1,000,000 USDC (6 decimals)
MAX_FEE_BPS="0"                # CCTP standard = no fee
ARB_DOMAIN="3"
BASE_DOMAIN="6"

# Custodian peer = MeshCustodian address as bytes32
CUSTODIAN_PEER="0x$(printf '%064x' $((MESH_CUSTODIAN_ARB)))"

echo "============================================="
echo " Crosschain Configuration"
echo "============================================="
echo ""
echo "Route ID:        $ROUTE_ID"
echo "Max in-flight:   $MAX_IN_FLIGHT"
echo "Max fee (bps):   $MAX_FEE_BPS"
echo "Custodian peer:  $CUSTODIAN_PEER"
echo ""

# =============================================================================
# BASE: Configure MeshNode
# =============================================================================
echo "[BASE] Configuring MeshNode..."
echo ""
echo "Actions (via Timelock governance):"
echo "  1. addRoute($ROUTE_ID, $ADAPTER_BASE, $ARB_DOMAIN, $CUSTODIAN_PEER, $MAX_IN_FLIGHT, $MAX_FEE_BPS)"
echo "  2. configureVault(0x3C7739173cca612B6394EE57131458185A5beC44, true, 2000, 8000)"
echo ""

# Generate calldata for Timelock proposals
echo "Generating Timelock calldata..."

# addRoute calldata
ADD_ROUTE_DATA=$(cast calldata "addRoute(bytes32,address,uint256,bytes32,uint256,uint16)" \
  "$ROUTE_ID" "$ADAPTER_BASE" "$ARB_DOMAIN" "$CUSTODIAN_PEER" "$MAX_IN_FLIGHT" "$MAX_FEE_BPS" 2>/dev/null || echo "MANUAL")

# configureVault calldata
BASE_VAULT="0x3C7739173cca612B6394EE57131458185A5beC44"
CONFIG_VAULT_DATA=$(cast calldata "configureVault(address,bool,uint16,uint16)" \
  "$BASE_VAULT" "true" "2000" "8000" 2>/dev/null || echo "MANUAL")

echo ""
echo "  addRoute calldata:      $ADD_ROUTE_DATA"
echo "  configureVault calldata: $CONFIG_VAULT_DATA"
echo ""
echo "Queue via Timelock (Base):"
echo "  cast send 0xb2b1A0c173549A498859822f20Da68be1bEA593D \\"
echo "    \"queueTransaction(address,bytes)\" \\"
echo "    $MESH_NODE_BASE \"$ADD_ROUTE_DATA\" \\"
echo "    --rpc-url $BASE_RPC --private-key $DEPLOYER_PRIVATE_KEY"
echo ""

# =============================================================================
# ARBITRUM: Configure MeshCustodian
# =============================================================================
echo "[ARBITRUM] Configuring MeshCustodian..."
echo ""
echo "Actions (via Timelock governance):"
echo "  1. trustAdapter($RELAY_ARB, true)   — relay delivers onBridgeIn"
echo "  2. trustAdapter($ADAPTER_ARB, true)  — adapter for bridgeBack"
echo ""

# trustAdapter calldata
TRUST_RELAY_DATA=$(cast calldata "trustAdapter(address,bool)" "$RELAY_ARB" "true" 2>/dev/null || echo "MANUAL")
TRUST_ADAPTER_DATA=$(cast calldata "trustAdapter(address,bool)" "$ADAPTER_ARB" "true" 2>/dev/null || echo "MANUAL")

echo "  trustAdapter(relay) calldata:   $TRUST_RELAY_DATA"
echo "  trustAdapter(adapter) calldata: $TRUST_ADAPTER_DATA"
echo ""
echo "Queue via Timelock (Arbitrum):"
echo "  cast send 0x694C38fb29fd14dECbBe11A15009aC7e728A686D \\"
echo "    \"queueTransaction(address,bytes)\" \\"
echo "    $MESH_CUSTODIAN_ARB \"$TRUST_RELAY_DATA\" \\"
echo "    --rpc-url $ARB_RPC --private-key $DEPLOYER_PRIVATE_KEY"
echo ""
echo "  cast send 0x694C38fb29fd14dECbBe11A15009aC7e728A686D \\"
echo "    \"queueTransaction(address,bytes)\" \\"
echo "    $MESH_CUSTODIAN_ARB \"$TRUST_ADAPTER_DATA\" \\"
echo "    --rpc-url $ARB_RPC --private-key $DEPLOYER_PRIVATE_KEY"
echo ""

# =============================================================================
# VERIFICATION
# =============================================================================
echo "============================================="
echo " VERIFICATION COMMANDS"
echo "============================================="
echo ""
echo "# Check MeshNode state (Base):"
echo "cast call $MESH_NODE_BASE \"routes(bytes32)(address,uint256,bytes32,uint256,uint256,uint16,bool)\" $ROUTE_ID --rpc-url $BASE_RPC"
echo "cast call $MESH_NODE_BASE \"vaults(address)(bool,uint16,uint16)\" $BASE_VAULT --rpc-url $BASE_RPC"
echo ""
echo "# Check MeshCustodian state (Arbitrum):"
echo "cast call $MESH_CUSTODIAN_ARB \"trustedAdapters(address)(bool)\" $RELAY_ARB --rpc-url $ARB_RPC"
echo "cast call $MESH_CUSTODIAN_ARB \"trustedAdapters(address)(bool)\" $ADAPTER_ARB --rpc-url $ARB_RPC"
echo ""
echo "# Check relay state:"
echo "cast call $RELAY_BASE \"target()(address)\" --rpc-url $BASE_RPC"
echo "cast call $RELAY_ARB \"target()(address)\" --rpc-url $ARB_RPC"
echo ""
echo "# Check adapter state:"
echo "cast call $ADAPTER_BASE \"relayPeer()(bytes32)\" --rpc-url $BASE_RPC"
echo "cast call $ADAPTER_ARB \"relayPeer()(bytes32)\" --rpc-url $ARB_RPC"
echo ""

echo "============================================="
echo " CONFIGURATION COMPLETE"
echo "============================================="
echo ""
echo "After Timelock delay (3600s), execute the queued transactions."
echo "Then start the relay keeper (see run-all.sh output)."
echo ""
