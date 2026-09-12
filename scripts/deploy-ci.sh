#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
export KUBECONFIG="${KUBECONFIG:-$GENERATED/kubeconfig}"

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
if [ ! -s "$KUBECONFIG" ]; then
  echo "Kubeconfig was not generated at $KUBECONFIG" >&2
  exit 1
fi
kubectl cluster-info >/dev/null

progress 75 "Installing platform services"
"$ROOT/scripts/install-platform.sh"

progress 85 "Rendering and applying Autonomous-SRE manifests"
"$ROOT/scripts/render-manifests.sh"

MANIFESTS="$GENERATED/manifests"

# Apply prerequisites deterministically. Gatekeeper creates the constraint CRD
# asynchronously after the ConstraintTemplate is accepted, so the constraint
# must not be submitted in the same bulk apply.
kubectl apply -f "$MANIFESTS/00-namespaces.yaml"
kubectl apply -f "$MANIFESTS/gatekeeper-baseline.yaml"

GATEKEEPER_TEMPLATE="k8srequiredrunasnonroot"
GATEKEEPER_KIND="K8sRequiredRunAsNonRoot"
GATEKEEPER_CRD=""

for attempt in $(seq 1 60); do
  GATEKEEPER_CRD="$(
    kubectl get crd -o json 2>/dev/null \
      | jq -r --arg kind "$GATEKEEPER_KIND" '.items[] | select(.spec.names.kind == $kind) | .metadata.name' \
      | head -n1
  )"

  if [ -n "$GATEKEEPER_CRD" ]; then
    break
  fi

  template_json="$(kubectl get constrainttemplate "$GATEKEEPER_TEMPLATE" -o json 2>/dev/null || true)"
  if [ -n "$template_json" ] && printf '%s' "$template_json" | jq -e '[.status.byPod[]?.errors[]?] | length > 0' >/dev/null 2>&1; then
    echo "Gatekeeper rejected ConstraintTemplate $GATEKEEPER_TEMPLATE:" >&2
    printf '%s' "$template_json" | jq '[.status.byPod[]?.errors[]?]' >&2
    exit 1
  fi

  if [ -n "$template_json" ] && printf '%s' "$template_json" | jq -e '.status.created == true' >/dev/null 2>&1; then
    echo "Gatekeeper reports the template as created; discovering generated CRD..."
  fi

  wait_progress "Waiting for Gatekeeper constraint CRD" "$attempt" 60
  sleep 2
done

if [ -z "$GATEKEEPER_CRD" ]; then
  echo "Gatekeeper created the template but the generated CRD for kind $GATEKEEPER_KIND could not be discovered." >&2
  kubectl get constrainttemplate "$GATEKEEPER_TEMPLATE" -o yaml >&2 || true
  kubectl get crd -o custom-columns='NAME:.metadata.name,KIND:.spec.names.kind' | grep -i 'gatekeeper\|requiredrunasnonroot' >&2 || true
  exit 1
fi

echo "Gatekeeper constraint CRD discovered: $GATEKEEPER_CRD"
kubectl wait --for=condition=Established "crd/$GATEKEEPER_CRD" --timeout=2m
kubectl apply -f "$MANIFESTS/gatekeeper-constraint.yaml"

# Apply all remaining manifests one file at a time so failures are explicit
# and ordering is reproducible across local and GitHub-hosted executions.
for manifest in "$MANIFESTS"/*.yaml; do
  case "$(basename "$manifest")" in
    00-namespaces.yaml|gatekeeper-baseline.yaml|gatekeeper-constraint.yaml)
      continue
      ;;
  esac
  echo "Applying $(basename "$manifest")"
  kubectl apply -f "$manifest"
done

# The OPA policy is rendered as a ConfigMap. Reapplying an unchanged Deployment
# does not restart its pods or clear an earlier ProgressDeadlineExceeded state.
# Start a fresh rollout so OPA loads the current policy before verification.
echo "Restarting OPA to load the rendered policy"
kubectl -n sre-system rollout restart deployment/opa

progress 92 "Initializing local AI model"
"$ROOT/scripts/initialize-model.sh"

progress 97 "Verifying end-to-end deployment"
"$ROOT/scripts/verify.sh"

progress 100 "Production deployment verified"
