#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_repo

ADMIN_TOKEN="$(gh auth token)"
[ -n "$ADMIN_TOKEN" ] || { echo "GitHub CLI authentication token is unavailable." >&2; exit 1; }
gh secret set RUNNER_ADMIN_TOKEN --repo "$GITHUB_REPOSITORY" --env production --body "$ADMIN_TOKEN"
echo "Dynamic build-runner administration credential configured."
