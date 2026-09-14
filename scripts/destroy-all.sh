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
export TF_VAR_runner_type="$RUNNER_TYPE"

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

# Scaleway CLI 2.58.x renders list commands as deterministic tables where
# the first two columns are ID and NAME. Using that native output avoids
# depending on JSON envelope shapes that differ across CLI/API versions.
managed_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && ($2 == "autonomous-sre-cp-01" || $2 ~ /^autonomous-sre-worker-/ || $2 == "autonomous-sre-runner-01") {print $1}'
}

platform_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && ($2 == "autonomous-sre-cp-01" || $2 ~ /^autonomous-sre-worker-/) {print $1}'
}

runner_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && $2 == "autonomous-sre-runner-01" {print $1}'
}

security_group_ids() {
  local name="$1"
  scw instance security-group list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk -v name="$name" 'NR > 1 && $2 == name {print $1}'
}

private_network_ids() {
  scw vpc private-network list project-id="$SCW_PROJECT_ID" region="$SCW_REGION" \
    | awk 'NR > 1 && $2 == "autonomous-sre-cluster" {print $1}'
}

vpc_ids() {
  scw vpc vpc list project-id="$SCW_PROJECT_ID" region="$SCW_REGION" \
    | awk 'NR > 1 && $2 == "autonomous-sre-vpc" {print $1}'
}

delete_servers() {
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting Scaleway Instance $id and its attached IP/volumes..."
    retry 3 3 scw instance server delete "$id" zone="$SCW_ZONE" force-shutdown=true with-volumes=all with-ip=true
  done
}

delete_named_security_groups() {
  local name="$1" id
  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting security group $name ($id)..."
    retry 5 3 scw instance security-group delete "$id" zone="$SCW_ZONE"
  done < <(security_group_ids "$name")
}

delete_platform_network_orphans() {
  local id

  delete_servers < <(platform_server_ids)
  sleep 3

  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting private network $id..."
    retry 5 3 scw vpc private-network delete "$id" region="$SCW_REGION"
  done < <(private_network_ids)

  delete_named_security_groups "autonomous-sre-cluster"

  while read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting VPC $id..."
    retry 5 3 scw vpc vpc delete "$id" region="$SCW_REGION"
  done < <(vpc_ids)
}

delete_runner_orphans() {
  delete_servers < <(runner_server_ids)
  delete_named_security_groups "autonomous-sre-runner"
}

verify_destroyed() {
  local leftovers=0

  if [ -n "$(managed_server_ids)" ]; then
    echo "Managed Autonomous-SRE Instances still exist." >&2
    leftovers=1
  fi
  if [ -n "$(security_group_ids autonomous-sre-cluster)" ] || [ -n "$(security_group_ids autonomous-sre-runner)" ]; then
    echo "Managed Autonomous-SRE security groups still exist." >&2
    leftovers=1
  fi
  if [ -n "$(private_network_ids)" ]; then
    echo "Managed Autonomous-SRE private network still exists." >&2
    leftovers=1
  fi
  if [ -n "$(vpc_ids)" ]; then
    echo "Managed Autonomous-SRE VPC still exists." >&2
    leftovers=1
  fi

  [ "$leftovers" -eq 0 ] || {
    echo "Destroy verification failed. Remote state is being kept for recovery." >&2
    exit 1
  }
}

# Lifecycle invariant: runner first on deploy, runner last on destroy.
progress 10 "Removing Kubernetes Instances before Private NIC cleanup"
delete_servers < <(platform_server_ids)

progress 30 "Destroying platform state-managed resources"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false

progress 50 "Cleaning any platform resources orphaned by a previous interrupted destroy"
delete_platform_network_orphans

progress 62 "Switching CI to GitHub-hosted fallback"
gh variable set CI_RUNNER --repo "$GITHUB_REPOSITORY" --body "ubuntu-latest"

progress 65 "Deregistering GitHub Actions runner after platform teardown"
RUNNER_ID="$(gh api "repos/$GITHUB_REPOSITORY/actions/runners" --jq '.runners[] | select(.name=="autonomous-sre-scaleway-01") | .id' 2>/dev/null || true)"
if [ -n "$RUNNER_ID" ]; then
  gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/runners/$RUNNER_ID" >/dev/null
fi

progress 75 "Destroying runner last"
delete_servers < <(runner_server_ids)
tofu -chdir="$ROOT/infrastructure/opentofu-runner" init -input=false -backend-config="$GENERATED/runner-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-runner" destroy -auto-approve -input=false

progress 88 "Cleaning any runner resources orphaned by a previous interrupted destroy"
delete_runner_orphans

progress 95 "Verifying that no managed Scaleway resources remain"
verify_destroyed

gh variable delete RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true

# The state backend is intentionally the last resource removed. Normal deploys,
# plans and application-only destroys reuse it; only destroy-all removes it.
# Never remove it unless every managed cloud resource has been verified absent.
progress 98 "Deleting remote state backend"
"$ROOT/scripts/delete-state.sh"

progress 100 "Destroy complete"
echo "Full platform destroyed, including the Scaleway Object Storage state backend."
