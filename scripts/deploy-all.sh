#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
"$ROOT/scripts/configure.sh"
"$ROOT/scripts/init-repository.sh"
load_config
require_repo
"$ROOT/scripts/bootstrap-state.sh"
"$ROOT/scripts/bootstrap-runner.sh"

run_workflow_and_wait build.yml
run_workflow_and_wait deploy.yml

load_scw_credentials
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
FQDN="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_fqdn)"
echo
echo "=================================================="
echo "FULL AUTONOMOUS-SRE PLATFORM DEPLOYED"
echo "Dashboard: https://$FQDN"
echo "Alert recipient: $ALERT_EMAIL"
echo "=================================================="
