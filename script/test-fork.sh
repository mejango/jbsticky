#!/bin/sh
# Reuse the deployment environment for read-only tests against pinned mainnet state.
set -eu
cd "$(dirname "$0")/.."
set -a
if [ -n "${STICKY_ENV_FILE:-}" ]; then
  . "$STICKY_ENV_FILE"
elif [ -f ./.env ]; then
  . ./.env
fi
set +a
: "${RPC_ETHEREUM_MAINNET:?Set RPC_ETHEREUM_MAINNET to an Ethereum archive RPC}"
: "${RPC_BASE_MAINNET:?Set RPC_BASE_MAINNET to a Base archive RPC}"
export FOUNDRY_PROFILE=fork
exec forge test --deny notes --summary --detailed --skip '*/script/**' "$@"
