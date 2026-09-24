#!/bin/sh
# Run from the package root; optionally share deploy-all-v6's existing environment.
set -eu
cd "$(dirname "$0")/.."
set -a
if [ -n "${STICKY_ENV_FILE:-}" ]; then
  . "$STICKY_ENV_FILE"
elif [ -f ./.env ]; then
  . ./.env
fi
set +a
export FOUNDRY_PROFILE=deploy
exec node script/deploy.mjs "$@"
