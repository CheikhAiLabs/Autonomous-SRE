#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

progress 5 "Installing deployment tooling"
"$ROOT/scripts/install-deploy-tools.sh"

progress 10 "Preparing Scaleway remote state"
"$ROOT/scripts/bootstrap-state.sh"

if [ -z "${RUNNER_CIDR:-}" ]; then
  echo "RUNNER_CIDR is required for production deployment." >&2
  exit 1
fi

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR"
export TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE"
export TF_VAR_worker_type="$WORKER_TYPE"
export TF_VAR_worker_count="$WORKER_COUNT"

progress 18 "Initializing OpenTofu platform stack"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init \
  -input=false \
  -reconfigure \
  -backend-config="$GENERATED/platform-backend.hcl"

progress 30 "Provisioning Scaleway platform infrastructure"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" apply -input=false -auto-approve

progress 45 "Preparing Ansible inventory and dependencies"
"$ROOT/scripts/render-inventory.sh"
"$ROOT/.deploy-venv/bin/ansible-galaxy" collection install \
  -r "$ROOT/infrastructure/ansible/requirements.yml" \
  --force >/dev/null

export ANSIBLE_ROLES_PATH="$ROOT/infrastructure/ansible/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_RETRY_FILES_ENABLED=False

progress 50 "Waiting for all Scaleway nodes to accept SSH"
ssh_ready=false
for attempt in $(seq 1 30); do
  if "$ROOT/.deploy-venv/bin/ansible" all \
    -i "$GENERATED/inventory.ini" \
    -m ansible.builtin.ping \
    -T 5 \
    -o >/dev/null 2>&1; then
    ssh_ready=true
    [ -t 1 ] && printf '\n' || true
    break
  fi
  wait_progress "Waiting for cluster SSH" "$attempt" 30
  sleep 10
done

if [ "$ssh_ready" != true ]; then
  echo "Cluster nodes did not become reachable over SSH in time." >&2
  "$ROOT/.deploy-venv/bin/ansible" all \
    -i "$GENERATED/inventory.ini" \
    -m ansible.builtin.ping \
    -T 5 \
    -o || true
  exit 1
fi

progress 55 "Installing and configuring K3s cluster"
"$ROOT/.deploy-venv/bin/ansible-playbook" \
  -i "$GENERATED/inventory.ini" \
  "$ROOT/infrastructure/ansible/playbooks/cluster.yml"

progress 65 "Fetching hardened kubeconfig"
"$ROOT/scripts/fetch-kubeconfig.sh"

progress 75 "Installing platform services"
"$ROOT/scripts/install-platform.sh"

progress 85 "Rendering and applying Autonomous-SRE manifests"
"$ROOT/scripts/render-manifests.sh"
kubectl apply -f "$GENERATED/manifests"

progress 92 "Initializing local AI model"
"$ROOT/scripts/initialize-model.sh"

progress 97 "Verifying end-to-end deployment"
"$ROOT/scripts/verify.sh"

progress 100 "Production deployment verified"
