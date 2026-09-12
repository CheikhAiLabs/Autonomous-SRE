#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

BUCKET="cheikhailabs-autonomous-sre-tfstate-${SCW_PROJECT_ID:0:12}"

if scw object bucket list region="$SCW_REGION" project-id="$SCW_PROJECT_ID" -o json \
  | jq -e --arg n "$BUCKET" '.[] | select(.name==$n)' >/dev/null; then
  echo "Deleting remote-state bucket and all stored state: $BUCKET"
  scw object bucket delete "$BUCKET" region="$SCW_REGION" >/dev/null
  echo "Remote-state bucket deletion requested: $BUCKET"
else
  echo "Remote-state bucket already absent: $BUCKET"
fi

rm -f \
  "$GENERATED/state-bucket" \
  "$GENERATED/runner-backend.hcl" \
  "$GENERATED/platform-backend.hcl"
