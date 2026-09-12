#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

progress 5 "Installing deployment tooling"
"$ROOT/scripts/install-deploy-tools.sh"
export PATH="$ROOT/.deploy-venv/bin:$PATH"

progress 10 "Preparing Scaleway remote state"
"$ROOT/scripts/bootstrap-state.sh"

: "${RUNNER_CIDR:?RUNNER_CIDR must be supplied by the GitHub production environment}"
export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR"
export TF_VAR_runner_cidr="$RUNNER_CIDR"
export TF_VAR_control_plane_type="$CONTROL_PLANE_TYPE"
export TF_VAR_worker_type="$WORKER_TYPE"
export TF_VAR_worker_count="$WORKER_COUNT"

progress 18 "Initializing OpenTofu platform stack"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl"

progress 30 "Provisioning Scaleway platform infrastructure"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" apply -input=false -auto-approve

progress 45 "Preparing Ansible inventory and dependencies"
"$ROOT/scripts/render-inventory.sh"
ANSIBLE_CONFIG="$ROOT/infrastructure/ansible/ansible.cfg" \
  ansible-galaxy collection install -r "$ROOT/infrastructure/ansible/requirements.yml" >/dev/null

progress 55 "Installing and configuring K3s cluster"
ANSIBLE_CONFIG="$ROOT/infrastructure/ansible/ansible.cfg" \
  ansible-playbook -i "$GENERATED/inventory.ini" "$ROOT/infrastructure/ansible/playbooks/cluster.yml"

progress 65 "Fetching Kubernetes configuration"
"$ROOT/scripts/fetch-kubeconfig.sh"
export KUBECONFIG="$GENERATED/kubeconfig"

progress 75 "Installing Cilium and platform services"
"$ROOT/scripts/install-platform.sh"

progress 85 "Deploying Autonomous-SRE workloads"
"$ROOT/scripts/render-manifests.sh"
kubectl apply -f "$GENERATED/manifests"

progress 92 "Initializing local AI model"
"$ROOT/scripts/initialize-model.sh"

progress 97 "Running end-to-end verification"
"$ROOT/scripts/verify.sh"

progress 100 "Production deployment verified"
