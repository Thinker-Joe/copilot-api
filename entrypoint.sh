#!/bin/sh
set -eu

PORT="${PORT:-4141}"
export HOST="${HOST:-0.0.0.0}"
# Keep the token out of the process list; the server reads it from the env.
export COPILOT_API_GITHUB_TOKEN="${COPILOT_API_GITHUB_TOKEN:-$GH_TOKEN}"

if [ "$#" -gt 0 ] && [ "$1" = "--auth" ]; then
  shift
  exec bun --use-system-ca run dist/main.js auth "$@"
fi

if [ "$#" -gt 0 ] && [ "$1" = "auth" ]; then
  exec bun --use-system-ca run dist/main.js "$@"
fi

set -- start --port "$PORT" --proxy-env "$@"

exec bun --use-system-ca run dist/main.js "$@"
