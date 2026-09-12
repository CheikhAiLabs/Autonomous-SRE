#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/install-deploy-tools.sh"
export PATH="$ROOT/.deploy-venv/bin:$PATH"
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

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl"
tofu -chdir="$ROOT/infrastructure/opentofu-platform" apply -input=false -auto-approve

"$ROOT/scripts/render-inventory.sh"
ANSIBLE_CONFIG="$ROOT/infrastructure/ansible/ansible.cfg" \
  ansible-galaxy collection install -r "$ROOT/infrastructure/ansible/requirements.yml" >/dev/null
ANSIBLE_CONFIG="$ROOT/infrastructure/ansible/ansible.cfg" \
  ansible-playbook -i "$GENERATED/inventory.ini" "$ROOT/infrastructure/ansible/playbooks/cluster.yml"

"$ROOT/scripts/fetch-kubeconfig.sh"
export KUBECONFIG="$GENERATED/kubeconfig"
"$ROOT/scripts/install-platform.sh"
"$ROOT/scripts/render-manifests.sh"
kubectl apply -f "$GENERATED/manifests"
"$ROOT/scripts/initialize-model.sh"
"$ROOT/scripts/verify.sh"
