#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

progress 5 "Preparing portable configuration"
"$ROOT/scripts/configure.sh"

progress 10 "Preparing GitHub repository"
"$ROOT/scripts/init-repository.sh"

load_config
require_repo

# A previous interrupted teardown must never leave workflows targeting a runner
# that no longer exists. GitHub-hosted remains the fallback until bootstrap has
# positively confirmed the dedicated runner is online.
gh variable set RUNNER_ONLINE --repo "$GITHUB_REPOSITORY" --body "false"
gh variable delete CI_RUNNER --repo "$GITHUB_REPOSITORY" 2>/dev/null || true

progress 20 "Preparing Scaleway Object Storage remote state"
"$ROOT/scripts/bootstrap-state.sh"

progress 40 "Provisioning and registering Scaleway GitHub runner"
"$ROOT/scripts/bootstrap-runner.sh"

# bootstrap-runner still writes the legacy CI_RUNNER variable for compatibility;
# the new lifecycle uses only RUNNER_ONLINE, so remove the obsolete selector.
gh variable delete CI_RUNNER --repo "$GITHUB_REPOSITORY" 2>/dev/null || true
gh variable set RUNNER_ONLINE --repo "$GITHUB_REPOSITORY" --body "true"

progress 55 "Building, scanning, signing and publishing application images"
run_workflow_and_wait build.yml

progress 65 "Starting production deployment workflow"
run_workflow_and_wait deploy.yml

progress 98 "Reading final platform endpoint"
load_scw_credentials

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
FQDN="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_fqdn)"

progress 100 "Deployment complete"
echo
echo "=================================================="
echo "FULL AUTONOMOUS-SRE PLATFORM DEPLOYED"
echo "Dashboard: https://$FQDN"
echo "Alert recipient: $ALERT_EMAIL"
echo "GitHub Actions: https://github.com/$GITHUB_REPOSITORY/actions"
echo "=================================================="
