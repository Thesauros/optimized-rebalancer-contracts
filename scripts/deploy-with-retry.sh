#!/usr/bin/env bash
# Retries `hardhat deploy --network <network>` until a run completes without error.
# Each retry resumes from saved deployment records; orphaned on-chain
# instances from crashed runs are harmless (nothing references them).
# Usage: deploy-with-retry.sh [network] [gasprice-wei]
set -u
cd "$(dirname "$0")/.."

NETWORK="${1:-base}"
GASPRICE="${2:-}"
EXTRA_ARGS=()
if [ -n "$GASPRICE" ]; then
  EXTRA_ARGS=(--gasprice "$GASPRICE")
fi

for i in 1 2 3 4 5 6 7 8; do
  echo "===== attempt $i ($NETWORK) ====="
  npx hardhat deploy --network "$NETWORK" "${EXTRA_ARGS[@]}" >"/tmp/dep-attempt-$i.log" 2>&1
  if grep -q "still pending" "/tmp/dep-attempt-$i.log"; then
    echo "attempt $i stopped on a pending tx prompt, waiting for it to mine..."
    sleep 60
    continue
  fi
  if ! grep -q "unexpected error" "/tmp/dep-attempt-$i.log"; then
    echo "DEPLOY_COMPLETED on attempt $i"
    tail -5 "/tmp/dep-attempt-$i.log"
    exit 0
  fi
  echo "attempt $i failed, last lines:"
  tail -3 "/tmp/dep-attempt-$i.log"
  sleep 5
done

echo "DEPLOY_FAILED_AFTER_RETRIES"
exit 1
