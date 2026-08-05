#!/usr/bin/env bash
# Retries `hardhat deploy --network base` until a run completes without error.
# Each retry resumes from saved deployment records; orphaned on-chain
# instances from crashed runs are harmless (nothing references them).
set -u
cd "$(dirname "$0")/.."

for i in 1 2 3 4 5 6 7 8; do
  echo "===== attempt $i ====="
  npx hardhat deploy --network base >"/tmp/dep-attempt-$i.log" 2>&1
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
