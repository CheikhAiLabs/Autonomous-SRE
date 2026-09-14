#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_repo

RUNNER_STATUS="$(gh api "repos/$GITHUB_REPOSITORY/actions/runners" --jq '.runners[] | select(.name=="autonomous-sre-scaleway-01") | .status' 2>/dev/null || true)"
if [ "$RUNNER_STATUS" != "online" ]; then
  echo "Dedicated runner autonomous-sre-scaleway-01 is not online. Use make deploy-all to bootstrap it first." >&2
  exit 1
fi

"$ROOT/scripts/configure-build-runner-admin.sh"
gh variable delete CI_RUNNER --repo "$GITHUB_REPOSITORY" 2>/dev/null || true
gh variable set RUNNER_ONLINE --repo "$GITHUB_REPOSITORY" --body "true"
gh variable set AUTOMATIC_DEPLOY --repo "$GITHUB_REPOSITORY" --body "true"

run_workflow_and_wait build.yml
run_workflow_and_wait deploy.yml
