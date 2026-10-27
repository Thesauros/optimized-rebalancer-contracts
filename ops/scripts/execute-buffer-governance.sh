#!/usr/bin/env bash
# Installed as a one-shot systemd service, after the queued operation's ETA.
# Pass an immutable image ID. No keys are copied out of Compose env files.
set -euo pipefail
cd /root/optimized-rebalancer-contracts
image_id="${1:?immutable ops image ID required}"
compose=(docker compose -f ops/docker-compose.yml)
exec 9>/run/xc-buffer-governance.lock
flock -n 9
# The CLI shares the stand signer. Restart operators afterwards to refresh nonces.
trap 'docker start ops-operators-1 >/dev/null' EXIT
"${compose[@]}" stop operators
# Pin the code even if another ops image is built before the timer fires.
docker run --rm --network host \
  --env-file ops/.env.server --env-file ops/.env.keys \
  --mount type=volume,src=ops_ops-data,dst=/data \
  "$image_id" src/buffer-governance.ts execute --yes
