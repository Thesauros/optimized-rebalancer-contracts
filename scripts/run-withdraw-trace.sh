#!/usr/bin/env bash
# Fork-test runner for the new vault withdraw trace.
set -euo pipefail
cd "$(dirname "$0")/.."

export VAULT="$(node -p "require('./deployments/base/USDCRebalancerProxy.json').address")"
export DEPLOYER_ADDR="$(node -p "require('dotenv').config() && new (require('ethers').Wallet)(process.env.DEPLOYER_PRIVATE_KEY).address")"
export BASE_RPC_URL="$(node -p "require('dotenv').config() && process.env.BASE_RPC_URL")"

forge test --match-path test/forking/NewVaultWithdraw.t.sol -vvvv
