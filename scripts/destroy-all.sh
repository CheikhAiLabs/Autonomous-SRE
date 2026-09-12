#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null
read -r -p "Type DESTROY-ALL to remove platform and runner: " CONFIRM
[ "$CONFIRM" = "DESTROY-ALL" ] || { echo "Cancelled"; exit 1; }

RUNNER_CIDR="$(gh variable get RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true)"
[ -n "$RUNNER_CIDR" ] || RUNNER_CIDR="$OPERATOR_CIDR"
export TF_VAR_project_id="$SCW_PROJECT_ID" TF_VAR_region="$SCW_REGION" TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR" TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE" TF_VAR_worker_type="$WORKER_TYPE" TF_VAR_worker_count="$WORKER_COUNT"

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false || true

RUNNER_ID="$(gh api "repos/$GITHUB_REPOSITORY/actions/runners" --jq '.runners[] | select(.name=="autonomous-sre-scaleway-01") | .id' 2>/dev/null || true)"
if [ -n "$RUNNER_ID" ]; then
  gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/runners/$RUNNER_ID" >/dev/null || true
fi
export TF_VAR_runner_type="$RUNNER_TYPE"
tofu -chdir="$ROOT/infrastructure/opentofu-runner" init -input=false -backend-config="$GENERATED/runner-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-runner" destroy -auto-approve -input=false

gh variable delete RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true

# The state backend is intentionally the last resource removed. Normal deploys,
# plans and application-only destroys reuse it; only destroy-all removes it.
"$ROOT/scripts/delete-state.sh"

echo "Full platform destroyed, including the Scaleway Object Storage state backend."
