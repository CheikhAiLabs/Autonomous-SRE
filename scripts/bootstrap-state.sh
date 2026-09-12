#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

BUCKET="${STATE_BUCKET:-cheikhailabs-autonomous-sre-tfstate-${SCW_PROJECT_ID:0:13}}"
ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"

bucket_exists() {
  aws \
    --endpoint-url "$ENDPOINT" \
    s3api head-bucket \
    --bucket "$BUCKET" \
    >/dev/null 2>&1
}

if bucket_exists; then
  echo "Remote-state bucket already exists: $BUCKET"
else
  echo "Creating remote-state bucket: $BUCKET"
  scw object bucket create \
    name="$BUCKET" \
    region="$SCW_REGION" \
    enable-versioning=true \
    >/dev/null
  echo "Remote-state bucket created: $BUCKET"
fi

aws \
  --endpoint-url "$ENDPOINT" \
  s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled \
  >/dev/null

generate_backend() {
  local key="$1" dest="$2"
  cat >"$dest" <<EOF
bucket = "$BUCKET"
key    = "$key"
region = "$SCW_REGION"
endpoints = {
  s3 = "$ENDPOINT"
}
use_lockfile                 = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
EOF
}

generate_backend "runner/terraform.tfstate" "$GENERATED/runner-backend.hcl"
generate_backend "platform/terraform.tfstate" "$GENERATED/platform-backend.hcl"
echo "$BUCKET" > "$GENERATED/state-bucket"

echo "Remote state ready: $BUCKET"
