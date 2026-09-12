#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh"

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR"
export TF_VAR_runner_type="$RUNNER_TYPE"

echo "== Runner plan =="
tofu -chdir="$ROOT/infrastructure/opentofu-runner" init -input=false -backend-config="$GENERATED/runner-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-runner" validate
tofu -chdir="$ROOT/infrastructure/opentofu-runner" plan -input=false

RUNNER_CIDR="$(tofu -chdir="$ROOT/infrastructure/opentofu-runner" output -raw runner_cidr 2>/dev/null || true)"
if [ -z "$RUNNER_CIDR" ]; then
  RUNNER_CIDR="${OPERATOR_CIDR}"
  echo "Runner not deployed yet; platform plan uses operator CIDR as temporary runner CIDR."
fi

export TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE"
export TF_VAR_worker_type="$WORKER_TYPE"
export TF_VAR_worker_count="$WORKER_COUNT"

echo
echo "== Platform plan =="
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" validate
tofu -chdir="$ROOT/infrastructure/opentofu-platform" plan -input=false
