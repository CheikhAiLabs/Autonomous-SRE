#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null
CONFIRM="${AUTO_CONFIRM_DESTROY:-}"
if [ -z "$CONFIRM" ]; then
  read -r -p "Type DESTROY to remove the Kubernetes platform: " CONFIRM
fi
[ "$CONFIRM" = "DESTROY" ] || { echo "Cancelled"; exit 1; }
RUNNER_CIDR="$(gh variable get RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true)"
[ -n "$RUNNER_CIDR" ] || RUNNER_CIDR="$OPERATOR_CIDR"
export TF_VAR_project_id="$SCW_PROJECT_ID" TF_VAR_region="$SCW_REGION" TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR" TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE" TF_VAR_worker_type="$WORKER_TYPE" TF_VAR_worker_count="$WORKER_COUNT"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false
echo "Platform destroyed. Runner and remote-state bucket preserved."
