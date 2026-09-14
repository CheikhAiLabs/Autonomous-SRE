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

# A deliberate platform destroy must not be immediately reversed by an
# automatic deployment triggered by an unrelated image build.
gh variable set AUTOMATIC_DEPLOY --repo "$GITHUB_REPOSITORY" --body "false" 2>/dev/null || true

RUNNER_CIDR="$(gh variable get RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true)"
[ -n "$RUNNER_CIDR" ] || RUNNER_CIDR="$OPERATOR_CIDR"
export TF_VAR_project_id="$SCW_PROJECT_ID" TF_VAR_region="$SCW_REGION" TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR" TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE" TF_VAR_worker_type="$WORKER_TYPE" TF_VAR_worker_count="$WORKER_COUNT"

retry() {
  local attempts="$1" delay="$2" try
  shift 2
  for try in $(seq 1 "$attempts"); do
    if "$@"; then
      return 0
    fi
    if [ "$try" -lt "$attempts" ]; then
      echo "Retrying in ${delay}s ($try/$attempts)..." >&2
      sleep "$delay"
    fi
  done
  return 1
}

platform_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && ($2 == "autonomous-sre-cp-01" || $2 ~ /^autonomous-sre-worker-/) {print $1}'
}

security_group_ids() {
  scw instance security-group list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && $2 == "autonomous-sre-cluster" {print $1}'
}

private_network_ids() {
  scw vpc private-network list project-id="$SCW_PROJECT_ID" region="$SCW_REGION" \
    | awk 'NR > 1 && $2 == "autonomous-sre-cluster" {print $1}'
}

vpc_ids() {
  scw vpc vpc list project-id="$SCW_PROJECT_ID" region="$SCW_REGION" \
    | awk 'NR > 1 && $2 == "autonomous-sre-vpc" {print $1}'
}

delete_platform_servers() {
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting Scaleway Instance $id and its attached IP/volumes..."
    retry 3 3 scw instance server delete "$id" zone="$SCW_ZONE" force-shutdown=true with-volumes=all with-ip=true
  done < <(platform_server_ids)
}

cleanup_platform_orphans() {
  local id

  delete_platform_servers
  sleep 3

  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting private network $id..."
    retry 5 3 scw vpc private-network delete "$id" region="$SCW_REGION"
  done < <(private_network_ids)

  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting cluster security group $id..."
    retry 5 3 scw instance security-group delete "$id" zone="$SCW_ZONE"
  done < <(security_group_ids)

  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting VPC $id..."
    retry 5 3 scw vpc vpc delete "$id" region="$SCW_REGION"
  done < <(vpc_ids)
}

verify_platform_destroyed() {
  local leftovers=0

  [ -z "$(platform_server_ids)" ] || { echo "Managed Kubernetes Instances still exist." >&2; leftovers=1; }
  [ -z "$(security_group_ids)" ] || { echo "Cluster security group still exists." >&2; leftovers=1; }
  [ -z "$(private_network_ids)" ] || { echo "Managed private network still exists." >&2; leftovers=1; }
  [ -z "$(vpc_ids)" ] || { echo "Managed VPC still exists." >&2; leftovers=1; }

  [ "$leftovers" -eq 0 ] || {
    echo "Platform destroy verification failed. Runner and remote state were preserved." >&2
    exit 1
  }
}

delete_platform_servers
sleep 3

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
if ! tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false; then
  echo "Initial OpenTofu destroy failed; cleaning cloud orphans before one required retry." >&2
  cleanup_platform_orphans
  tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false
fi

cleanup_platform_orphans
verify_platform_destroyed

echo "Platform destroyed and verified. Runner and remote-state bucket preserved."
