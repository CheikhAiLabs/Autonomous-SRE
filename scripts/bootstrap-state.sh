#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

BUCKET="cheikhailabs-autonomous-sre-tfstate-${SCW_PROJECT_ID:0:12}"

if ! scw object bucket list region="$SCW_REGION" project-id="$SCW_PROJECT_ID" -o json | jq -e --arg n "$BUCKET" '.[] | select(.name==$n)' >/dev/null; then
  echo "Creating remote-state bucket: $BUCKET"
  scw object bucket create name="$BUCKET" region="$SCW_REGION" project-id="$SCW_PROJECT_ID" >/dev/null
fi

# Best-effort versioning. Older/newer CLI shapes may expose this field differently.
scw object bucket update "$BUCKET" region="$SCW_REGION" versioning.enabled=true >/dev/null 2>&1 || true

generate_backend() {
  local key="$1" dest="$2"
  cat >"$dest" <<EOF
bucket = "$BUCKET"
key    = "$key"
region = "$SCW_REGION"
endpoints = {
  s3 = "https://s3.${SCW_REGION}.scw.cloud"
}
use_lockfile                  = true
skip_credentials_validation  = true
skip_region_validation       = true
skip_requesting_account_id   = true
EOF
}

generate_backend "runner/terraform.tfstate" "$GENERATED/runner-backend.hcl"
generate_backend "platform/terraform.tfstate" "$GENERATED/platform-backend.hcl"
echo "$BUCKET" > "$GENERATED/state-bucket"

echo "Remote state ready: $BUCKET"
