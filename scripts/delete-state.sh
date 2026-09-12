#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

BUCKET="${STATE_BUCKET:-cheikhailabs-autonomous-sre-tfstate-${SCW_PROJECT_ID:0:13}}"
ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"

if aws --endpoint-url "$ENDPOINT" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "Deleting remote-state bucket and all stored state: $BUCKET"

  # Remove current objects first, then all historical versions/delete markers.
  aws --endpoint-url "$ENDPOINT" s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true

  while true; do
    VERSIONS_JSON="$(aws --endpoint-url "$ENDPOINT" s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json)"
    COUNT="$(printf '%s' "$VERSIONS_JSON" | jq '((.Versions // []) + (.DeleteMarkers // [])) | length')"
    [ "$COUNT" -gt 0 ] || break

    DELETE_PAYLOAD="$(printf '%s' "$VERSIONS_JSON" | jq -c '{Objects: (((.Versions // []) + (.DeleteMarkers // [])) | map({Key: .Key, VersionId: .VersionId})), Quiet: true}')"
    aws --endpoint-url "$ENDPOINT" s3api delete-objects --bucket "$BUCKET" --delete "$DELETE_PAYLOAD" >/dev/null
  done

  scw object bucket delete "$BUCKET" region="$SCW_REGION" >/dev/null
  echo "Remote-state bucket deleted: $BUCKET"
else
  echo "Remote-state bucket already absent: $BUCKET"
fi

rm -f \
  "$GENERATED/state-bucket" \
  "$GENERATED/runner-backend.hcl" \
  "$GENERATED/platform-backend.hcl"
