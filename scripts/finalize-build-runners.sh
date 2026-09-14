#!/usr/bin/env bash
set -Eeuo pipefail

POOL_DIR="$HOME/.autonomous-sre"
mkdir -p "$POOL_DIR"
printf 'idle %s\n' "$(date +%s)" > "$POOL_DIR/build-pool.state"
echo "Build runner pool marked idle; TTL countdown started."
