#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
find "$ROOT/scripts" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
python3 -m compileall -q "$ROOT/src" "$ROOT/apps/api" "$ROOT/apps/worker" "$ROOT/apps/controller" "$ROOT/workloads/demo-service"
if command -v ruff >/dev/null 2>&1; then ruff check "$ROOT/src" "$ROOT/apps/api" "$ROOT/apps/worker" "$ROOT/apps/controller" "$ROOT/tests" "$ROOT/workloads/demo-service"; fi
tofu -chdir="$ROOT/infrastructure/opentofu-runner" fmt -check -recursive
tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" fmt -check -recursive
tofu -chdir="$ROOT/infrastructure/opentofu-platform" fmt -check -recursive
echo "Local checks passed"
