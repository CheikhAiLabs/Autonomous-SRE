#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null
read -r -p "Type DESTROY-ALL to remove platform and runner: " CONFIRM
[ "$CONFIRM" = "DESTROY-ALL" ] || { echo "Cancelled"; exit 1; }

# Stop new production work before touching infrastructure. From this point on,
# CI/Security/Build can use GitHub-hosted runners while the Scaleway runner is
# kept alive until all platform and temporary build resources are gone.
gh variable set RUNNER_ONLINE --repo "$GITHUB_REPOSITORY" --body "false" 2>/dev/null || true
gh variable set AUTOMATIC_DEPLOY --repo "$GITHUB_REPOSITORY" --body "false" 2>/dev/null || true
gh variable delete CI_RUNNER --repo "$GITHUB_REPOSITORY" 2>/dev/null || true

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

managed_server_ids() {
  scw instance server list project-id="$SCW_PROJECT_ID" zone="$SCW_ZONE" \
    | awk 'NR > 1 && ($2 == "autonomous-sre-cp-01" || $2 ~ /^autonomous-sre-worker-/ || $2 == "autonomous-sre-runner-01" || $2 ~ /^autonomous-sre-build-[0-9]+$/) {print $1}'
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

verify_platform_destroyed() {
  local leftovers=0

  [ -z "$(platform_server_ids)" ] || { echo "Managed Kubernetes Instances still exist." >&2; leftovers=1; }
  [ -z "$(security_group_ids autonomous-sre-cluster)" ] || { echo "Cluster security group still exists." >&2; leftovers=1; }
  [ -z "$(private_network_ids)" ] || { echo "Managed private network still exists." >&2; leftovers=1; }
  [ -z "$(vpc_ids)" ] || { echo "Managed VPC still exists." >&2; leftovers=1; }

  [ "$leftovers" -eq 0 ] || {
    echo "Platform destroy verification failed. Runner and remote state are being kept for recovery." >&2
    exit 1
  }
}

verify_destroyed() {
  local leftovers=0

  [ -z "$(managed_server_ids)" ] || { echo "Managed Autonomous-SRE Instances still exist." >&2; leftovers=1; }
  if [ -n "$(security_group_ids autonomous-sre-cluster)" ] || \
     [ -n "$(security_group_ids autonomous-sre-runner)" ] || \
     [ -n "$(security_group_ids autonomous-sre-build-runners)" ]; then
    echo "Managed Autonomous-SRE security groups still exist." >&2
    leftovers=1
  fi
  [ -z "$(private_network_ids)" ] || { echo "Managed Autonomous-SRE private network still exists." >&2; leftovers=1; }
  [ -z "$(vpc_ids)" ] || { echo "Managed Autonomous-SRE VPC still exists." >&2; leftovers=1; }

  [ "$leftovers" -eq 0 ] || {
    echo "Destroy verification failed. Remote state is being kept for recovery." >&2
    exit 1
  }
}

# Lifecycle invariant: primary runner first on deploy, primary runner last on destroy.
progress 10 "Removing Kubernetes Instances before Private NIC cleanup"
delete_servers < <(platform_server_ids)
sleep 3

progress 30 "Destroying platform state-managed resources"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
if ! tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false; then
  echo "Initial platform destroy failed; cleaning cloud orphans before one required retry." >&2
  delete_platform_network_orphans
  tofu -chdir="$ROOT/infrastructure/opentofu-platform" destroy -auto-approve -input=false
fi

progress 50 "Cleaning any platform resources orphaned by an interrupted destroy"
delete_platform_network_orphans

progress 60 "Verifying platform is gone before touching runners"
verify_platform_destroyed

progress 66 "Destroying temporary image-build runner pool"
RUNNER_CIDR="$RUNNER_CIDR" "$ROOT/scripts/destroy-build-runners.sh"

progress 72 "Deregistering primary GitHub Actions runner"
RUNNER_ID="$(gh api "repos/$GITHUB_REPOSITORY/actions/runners" --jq '.runners[] | select(.name=="autonomous-sre-scaleway-01") | .id' 2>/dev/null || true)"
if [ -n "$RUNNER_ID" ]; then
  gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/runners/$RUNNER_ID" >/dev/null || \
    echo "Warning: GitHub runner deregistration failed; continuing cloud teardown." >&2
fi

progress 80 "Destroying primary runner last"
delete_servers < <(runner_server_ids)
sleep 3

tofu -chdir="$ROOT/infrastructure/opentofu-runner" init -input=false -backend-config="$GENERATED/runner-backend.hcl" >/dev/null
if ! tofu -chdir="$ROOT/infrastructure/opentofu-runner" destroy -auto-approve -input=false; then
  echo "Initial runner destroy failed; cleaning cloud orphans before one required retry." >&2
  delete_runner_orphans
  tofu -chdir="$ROOT/infrastructure/opentofu-runner" destroy -auto-approve -input=false
fi

progress 88 "Cleaning any runner resources orphaned by an interrupted destroy"
delete_runner_orphans

progress 95 "Verifying that no managed Scaleway resources remain"
verify_destroyed

gh variable delete RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production 2>/dev/null || true

# The state backend is intentionally the final cloud resource removed. Never
# remove it until every managed compute/network resource has been verified gone.
progress 98 "Deleting remote state backend"
"$ROOT/scripts/delete-state.sh"

progress 100 "Destroy complete"
echo "Full platform destroyed, including temporary build runners, primary runner and Scaleway Object Storage state backend."
