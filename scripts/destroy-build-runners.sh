#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

ADMIN_TOKEN="${RUNNER_ADMIN_TOKEN:-}"
if [ -z "$ADMIN_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  ADMIN_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

if [ -n "$ADMIN_TOKEN" ]; then
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners?per_page=100" \
    | jq -r '.runners[] | select(any(.labels[]?; .name == "autonomous-sre-build")) | .id' \
    | while read -r runner_id; do
        [ -n "$runner_id" ] || continue
        curl -fsSL -X DELETE \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $ADMIN_TOKEN" \
          -H "X-GitHub-Api-Version: 2026-03-10" \
          "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners/$runner_id" >/dev/null || true
      done
fi

"$ROOT/scripts/bootstrap-state.sh" >/dev/null

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_manager_cidr="${RUNNER_CIDR:-$OPERATOR_CIDR}"
export TF_VAR_runner_type="${BUILD_RUNNER_TYPE:-DEV1-M}"
export TF_VAR_runner_count="${BUILD_RUNNER_COUNT:-3}"

tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" init \
  -input=false \
  -backend-config="$GENERATED/build-runners-backend.hcl" >/dev/null

tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" destroy -input=false -auto-approve

echo "Ephemeral build runner pool destroyed."
