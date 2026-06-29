#!/bin/sh
set -eu

PORT="${PORT:-4141}"

if [ "$#" -gt 0 ] && [ "$1" = "--auth" ]; then
  shift
  exec bun --use-system-ca run dist/main.js auth "$@"
fi

if [ "$#" -gt 0 ] && [ "$1" = "auth" ]; then
  exec bun --use-system-ca run dist/main.js "$@"
fi

set -- start --port "$PORT" --proxy-env "$@"

if [ -n "${GH_TOKEN:-}" ]; then
  set -- "$@" --github-token "$GH_TOKEN"
fi

exec bun --use-system-ca run dist/main.js "$@"