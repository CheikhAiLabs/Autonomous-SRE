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

BUCKET="${STATE_BUCKET:-cheikhailabs-autonomous-sre-tfstate-${SCW_PROJECT_ID:0:13}}"
ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"
mkdir -p "$GENERATED"
cat > "$GENERATED/build-runners-backend.hcl" <<EOF
bucket = "$BUCKET"
key    = "build-runners/terraform.tfstate"
region = "$SCW_REGION"
endpoints = {
  s3 = "$ENDPOINT"
}
use_lockfile                 = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
EOF

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_manager_cidr="${RUNNER_CIDR:-$OPERATOR_CIDR}"
export TF_VAR_runner_type="${BUILD_RUNNER_TYPE:-DEV1-M}"
export TF_VAR_runner_count="${BUILD_RUNNER_COUNT:-3}"

build_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && $2 ~ /^autonomous-sre-build-[0-9]+$/ {print $1}'
}

delete_orphan_servers() {
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    scw instance server delete "$id" zone="$SCW_ZONE" force-shutdown=true with-volumes=all with-ip=true || true
  done < <(build_server_ids)
}

tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" init \
  -input=false \
  -backend-config="$GENERATED/build-runners-backend.hcl" >/dev/null

if ! tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" destroy -input=false -auto-approve; then
  echo "Initial build runner pool destroy failed; removing orphan instances before retry." >&2
  delete_orphan_servers
  tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" destroy -input=false -auto-approve
fi

delete_orphan_servers

if [ -n "$(build_server_ids)" ]; then
  echo "Build runner instances still exist after teardown." >&2
  exit 1
fi

echo "Ephemeral build runner pool destroyed."
