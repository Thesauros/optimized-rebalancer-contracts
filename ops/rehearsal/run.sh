#!/usr/bin/env bash
# Full deployment + operations rehearsal on local forks of Base and Arbitrum.
#
#   BASE_RPC_URL=... ops/rehearsal/run.sh                        # production profile, Safe governance
#   BASE_RPC_URL=... REHEARSAL_PROFILE=stand ops/rehearsal/run.sh # stand: one EOA, small limits, then rotation
#
# Starts two anvil forks (chain ids preserved), runs the four deployment phases
# on both with anvil keys and the real governance Safe (impersonated), then
# ops/rehearsal/e2e.ts drives a full cycle through the real services:
# deposit -> tick -> close -> tick -> clear -> claim -> allocate -> CCTP burn on
# Base -> relayer delivery on Arbitrum (local attester) -> tick -> monitor.
# Nothing touches a live network; manifests go to /tmp.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$PATH:$HOME/.foundry/bin"

BASE_FORK_URL="${BASE_RPC_URL:?set BASE_RPC_URL}"
ARB_FORK_URL="${ARBITRUM_FORK_URL:-https://arb1.arbitrum.io/rpc}"
LOGDIR=/tmp/xc-rehearsal-logs
rm -rf /tmp/xc-rehearsal "$LOGDIR" && mkdir -p "$LOGDIR"

anvil --fork-url "$BASE_FORK_URL" --chain-id 8453 --port 8545 --silent >"$LOGDIR/anvil-base.log" 2>&1 &
BASE_PID=$!
anvil --fork-url "$ARB_FORK_URL" --chain-id 42161 --port 8546 --silent >"$LOGDIR/anvil-arb.log" 2>&1 &
ARB_PID=$!
trap 'kill $BASE_PID $ARB_PID 2>/dev/null || true' EXIT
for port in 8545 8546; do
  for _ in $(seq 1 60); do cast block-number --rpc-url "http://127.0.0.1:$port" >/dev/null 2>&1 && break; sleep 1; done
done

# fresh keys per run: well-known anvil keys have real history (and nonces) on the forked chains
# order: 0 deployer, 1 nav updater, 2 executor, 3 guardian, 4 keeper/relayer, 5 user, 6 attester
KEYS=()
for _ in 0 1 2 3 4 5 6; do KEYS+=("$(cast wallet new --json | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d)[0].private_key))')"); done
addr() { cast wallet address --private-key "$1"; }

PROFILE=${REHEARSAL_PROFILE:-production}
export CROSSCHAIN_PROFILE=$PROFILE
REAL_SAFE=0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1
export REHEARSAL_DEPLOYER_KEY=${KEYS[0]}
if [ "$PROFILE" = stand ]; then
  # founder decision for the test stand: the deployer EOA holds governance and every role
  D=$(addr ${KEYS[0]})
  export CROSSCHAIN_SAFE=$D CROSSCHAIN_NAV_UPDATER=$D CROSSCHAIN_EXECUTOR=$D CROSSCHAIN_GUARDIAN=$D
  KEYS[1]=${KEYS[0]}; KEYS[2]=${KEYS[0]}; KEYS[3]=${KEYS[0]}
else
  export CROSSCHAIN_SAFE=$REAL_SAFE
  export CROSSCHAIN_NAV_UPDATER=$(addr ${KEYS[1]})
  export CROSSCHAIN_EXECUTOR=$(addr ${KEYS[2]})
  export CROSSCHAIN_GUARDIAN=$(addr ${KEYS[3]})
fi
export CROSSCHAIN_TIMELOCK_DELAY=1800
export CROSSCHAIN_MANIFEST_DIR=/tmp/xc-rehearsal
# both caches must live in the throwaway directory: their defaults are relative to
# the cwd, and state written against a fork must never be picked up by a real run
export TRANSFER_INDEX_FILE=/tmp/xc-rehearsal/transfer-index.json
export INDEXER_DB=/tmp/xc-rehearsal/indexer.sqlite
export RPC_BASE=http://127.0.0.1:8545
export RPC_ARBITRUM=http://127.0.0.1:8546
# broadcast through a different URL to the same node, so the read/send split
# (RoutedProvider) is exercised by every service in the rehearsal
export RPC_SEND_BASE=http://localhost:8545 RPC_SEND_ARBITRUM=http://localhost:8546
export NAV_UPDATER_PRIVATE_KEY=${KEYS[1]}
export EXECUTOR_PRIVATE_KEY=${KEYS[2]}
export GUARDIAN_PRIVATE_KEY=${KEYS[3]}
export KEEPER_PRIVATE_KEY=${KEYS[4]}
export RELAYER_PRIVATE_KEY=${KEYS[4]}
export USER_PRIVATE_KEY=${KEYS[5]}
export LOCAL_ATTESTER_KEY=${KEYS[6]}
export RELAYER_ATTESTATION=local
# hub needs >= 1: the reference block must precede the commit block and have a blockhash
export CONFIRMATIONS_BASE=1 CONFIRMATIONS_ARBITRUM=0
export LOG_RANGE=2000

DEPLOYER=$(addr ${KEYS[0]})
USER=$(addr ${KEYS[5]})
for k in "${KEYS[@]}"; do
  for rpc in $RPC_BASE $RPC_ARBITRUM; do cast rpc anvil_setBalance "$(addr $k)" 0x56BC75E2D63100000 --rpc-url $rpc >/dev/null; done
done
fund_usdc() { # rpc usdc holder amount   (FiatToken v2.2 balances at slot 9)
  local slot; slot=$(cast index address "$3" 9)
  cast rpc anvil_setStorageAt "$2" "$slot" "$(cast to-uint256 "$4")" --rpc-url "$1" >/dev/null
}
fund_usdc $RPC_BASE 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "$DEPLOYER" 10000000
fund_usdc $RPC_ARBITRUM 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 "$DEPLOYER" 10000000
fund_usdc $RPC_BASE 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "$USER" 1000000000000

echo "== phase 1"; npx hardhat run deploy/crosschain/01-deploy.ts --network baseLocal
npx hardhat run deploy/crosschain/01-deploy.ts --network arbitrumLocal
echo "== phase 2"; npx hardhat run deploy/crosschain/02-configure.ts --network baseLocal
npx hardhat run deploy/crosschain/02-configure.ts --network arbitrumLocal
echo "== phase 3"; npx hardhat run deploy/crosschain/03-handover.ts --network baseLocal
npx hardhat run deploy/crosschain/03-handover.ts --network arbitrumLocal

echo "== Safe accepts ProviderManager ownership (impersonated)"
for rpc in $( [ "$PROFILE" = stand ] || echo "$RPC_BASE $RPC_ARBITRUM" ); do
  net=$([ "$rpc" = "$RPC_BASE" ] && echo base || echo arbitrum)
  pm=$(node -e "console.log(require('/tmp/xc-rehearsal/$net/crosschain.json').contracts.ProviderManager)")
  cast rpc anvil_impersonateAccount $CROSSCHAIN_SAFE --rpc-url $rpc >/dev/null
  cast rpc anvil_setBalance $CROSSCHAIN_SAFE 0x8AC7230489E80000 --rpc-url $rpc >/dev/null
  cast send "$pm" "acceptOwnership()" --from $CROSSCHAIN_SAFE --unlocked --rpc-url $rpc >/dev/null
done

echo "== phase 4"; npx hardhat run deploy/crosschain/04-verify.ts --network baseLocal
npx hardhat run deploy/crosschain/04-verify.ts --network arbitrumLocal

echo "== phase 5 plan: a freshly handed-over deployment must match the registry"
for net in baseLocal arbitrumLocal; do
  out=$(npx hardhat run deploy/crosschain/05-governance-plan.ts --network $net)
  echo "$out"
  echo "$out" | grep -q "nothing to change" || { echo "governance plan not empty on $net"; exit 1; }
done

echo "== enable local CCTP attester on both forks"
ATTESTER=$(addr ${KEYS[6]})
for rpc in $RPC_BASE $RPC_ARBITRUM; do
  T=0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
  mgr=$(cast call $T "attesterManager()(address)" --rpc-url $rpc)
  cast rpc anvil_impersonateAccount "$mgr" --rpc-url $rpc >/dev/null
  cast rpc anvil_setBalance "$mgr" 0x8AC7230489E80000 --rpc-url $rpc >/dev/null
  cast send $T "enableAttester(address)" "$ATTESTER" --from "$mgr" --unlocked --rpc-url $rpc >/dev/null
  cast send $T "setSignatureThreshold(uint256)" 1 --from "$mgr" --unlocked --rpc-url $rpc >/dev/null
done

echo "== end-to-end cycle"
npx ts-node --transpile-only ops/rehearsal/e2e.ts

if [ "$PROFILE" = stand ]; then
  echo "== rotation: stand EOA -> Safe + fresh operational keys (06)"
  NEWK=(); for _ in 1 2 3; do NEWK+=("$(cast wallet new --json | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d)[0].private_key))')"); done
  export NEW_SAFE=$REAL_SAFE NEW_NAV_UPDATER=$(addr ${NEWK[0]}) NEW_EXECUTOR=$(addr ${NEWK[1]}) NEW_GUARDIAN=$(addr ${NEWK[2]})
  npx hardhat run deploy/crosschain/06-rotate-governance.ts --network baseLocal
  npx hardhat run deploy/crosschain/06-rotate-governance.ts --network arbitrumLocal

  echo "== treasury to the Safe through the Timelock (still owned by the EOA until the Safe accepts)"
  TL=$(node -e "console.log(require('/tmp/xc-rehearsal/base/crosschain.json').contracts.Timelock)")
  ACC=$(node -e "console.log(require('/tmp/xc-rehearsal/base/crosschain.json').contracts.TickAccountant)")
  NOW=$(cast block latest --field timestamp --rpc-url $RPC_BASE)
  ETA=$((NOW + 1800 + 60))
  DATA=$(cast abi-encode "f(address)" $REAL_SAFE)
  cast send $TL "queue(address,uint256,string,bytes,uint256)" $ACC 0 "setTreasury(address)" $DATA $ETA --private-key ${KEYS[0]} --rpc-url $RPC_BASE >/dev/null
  cast rpc evm_increaseTime 1900 --rpc-url $RPC_BASE >/dev/null; cast rpc evm_mine --rpc-url $RPC_BASE >/dev/null
  cast send $TL "execute(address,uint256,string,bytes,uint256)" $ACC 0 "setTreasury(address)" $DATA $ETA --private-key ${KEYS[0]} --rpc-url $RPC_BASE >/dev/null

  echo "== Safe accepts Timelock and ProviderManager ownership (impersonated)"
  for net in base arbitrum; do
    rpc=$([ $net = base ] && echo $RPC_BASE || echo $RPC_ARBITRUM)
    cast rpc anvil_impersonateAccount $REAL_SAFE --rpc-url $rpc >/dev/null
    cast rpc anvil_setBalance $REAL_SAFE 0x8AC7230489E80000 --rpc-url $rpc >/dev/null
    for c in Timelock ProviderManager; do
      a=$(node -e "console.log(require('/tmp/xc-rehearsal/$net/crosschain.json').contracts.$c)")
      cast send $a "acceptOwnership()" --from $REAL_SAFE --unlocked --rpc-url $rpc >/dev/null
    done
  done

  echo "== phase 4 with the production identities (limits are still stand-sized)"
  export CROSSCHAIN_SAFE=$REAL_SAFE CROSSCHAIN_NAV_UPDATER=$NEW_NAV_UPDATER CROSSCHAIN_EXECUTOR=$NEW_EXECUTOR CROSSCHAIN_GUARDIAN=$NEW_GUARDIAN
  npx hardhat run deploy/crosschain/04-verify.ts --network baseLocal
  npx hardhat run deploy/crosschain/04-verify.ts --network arbitrumLocal

  echo "== phase 5 with the production profile: limits must show up as Timelock changes"
  out=$(CROSSCHAIN_PROFILE=production npx hardhat run deploy/crosschain/05-governance-plan.ts --network baseLocal)
  echo "$out"
  echo "$out" | grep -q "vault limits -> production" || { echo "expected a limits change in the plan"; exit 1; }
  echo "STAND ROTATION PASSED"
fi
