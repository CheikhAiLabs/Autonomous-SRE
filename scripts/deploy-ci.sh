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
    -T 5 >/dev/null 2>&1; then
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
    -T 5 || true
  exit 1
fi

EXPECTED_NODE_COUNT="$((WORKER_COUNT + 1))"
DESIRED_K3S_VERSION="$(awk -F= '/^k3s_version=/{print $2; exit}' "$GENERATED/inventory.ini")"

fetch_existing_kubeconfig() {
  rm -f "$KUBECONFIG"
  if "$ROOT/scripts/fetch-kubeconfig.sh" >/dev/null 2>&1 \
    && [ -s "$KUBECONFIG" ] \
    && kubectl cluster-info >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$KUBECONFIG"
  return 1
}

existing_cluster_matches() {
  local nodes
  nodes="$(kubectl get nodes -o json 2>/dev/null || true)"
  [ -n "$nodes" ] || return 1

  jq -e \
    --argjson expected "$EXPECTED_NODE_COUNT" \
    --arg version "$DESIRED_K3S_VERSION" '
      (.items | length) == $expected and
      all(.items[]; .status.nodeInfo.kubeletVersion == $version)
    ' >/dev/null <<<"$nodes"
}

node_ready() {
  local node="$1"
  kubectl get node "$node" -o json 2>/dev/null \
    | jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
}

all_nodes_ready() {
  local nodes node
  mapfile -t nodes < <(kubectl get nodes -o json | jq -r '.items[].metadata.name')
  [ "${#nodes[@]}" -eq "$EXPECTED_NODE_COUNT" ] || return 1
  for node in "${nodes[@]}"; do
    node_ready "$node" || return 1
  done
}

cilium_on_node_healthy() {
  local node="$1"
  kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" -o json 2>/dev/null \
    | jq -e '
        (.items | length) == 1 and
        .items[0].metadata.deletionTimestamp == null and
        .items[0].status.phase == "Running" and
        ((.items[0].status.containerStatuses // []) | length) > 0 and
        all((.items[0].status.containerStatuses // [])[]; .ready == true)
      ' >/dev/null
}

ansible_host_for_node() {
  local node="$1" node_ip
  node_ip="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  [ -n "$node_ip" ] || return 1
  awk -v ip="$node_ip" '
    $0 ~ ("private_ip=" ip "([[:space:]]|$)") { print $1; exit }
  ' "$GENERATED/inventory.ini"
}

dump_worker_agent_diagnostics() {
  local ansible_host="$1" node="$2"
  echo "K3s agent diagnostics for $node ($ansible_host):" >&2
  timeout 30s "$ROOT/.deploy-venv/bin/ansible" "$ansible_host" \
    -i "$GENERATED/inventory.ini" \
    -T 10 \
    -m ansible.builtin.shell \
    -a 'set -o pipefail; systemctl status k3s-agent --no-pager -l || true; echo "--- journal ---"; journalctl -u k3s-agent -n 200 --no-pager || true; echo "--- resources ---"; df -h; free -m; echo "--- routes ---"; ip route' >&2 || true
  kubectl describe node "$node" >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 || true
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 >&2 || true
}

restart_worker_agent() {
  local node="$1" ansible_host attempt pod
  ansible_host="$(ansible_host_for_node "$node")"
  if [ -z "$ansible_host" ]; then
    echo "Could not map Kubernetes node $node to the Ansible inventory." >&2
    return 1
  fi

  echo "Node $node stopped reporting. Scheduling a bounded k3s-agent restart on $ansible_host."
  if ! timeout 25s "$ROOT/.deploy-venv/bin/ansible" "$ansible_host" \
    -i "$GENERATED/inventory.ini" \
    -T 10 \
    -m ansible.builtin.shell \
    -a 'systemctl reset-failed k3s-agent || true; unit="autonomous-sre-k3s-restart-$(date +%s)"; systemd-run --unit="$unit" --on-active=1s --collect /bin/systemctl restart k3s-agent >/dev/null; echo "$unit scheduled"'; then
    echo "Could not schedule the k3s-agent restart on $ansible_host within 25 seconds." >&2
    dump_worker_agent_diagnostics "$ansible_host" "$node"
    return 1
  fi

  # The restart itself runs as a transient systemd job on the worker. The CI
  # process never waits inside systemctl, so a wedged agent cannot hang the
  # deployment indefinitely.
  for attempt in $(seq 1 24); do
    if node_ready "$node" && cilium_on_node_healthy "$node"; then
      echo "$node recovered after restarting k3s-agent."
      return 0
    fi
    wait_progress "Waiting for $node to report Ready after k3s-agent restart" "$attempt" 24
    sleep 5
  done

  pod="$(kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" -o json \
    | jq -r '.items[]? | select(.metadata.deletionTimestamp != null) | .metadata.name' \
    | head -n1)"
  if [ -n "$pod" ]; then
    echo "Removing stale terminating Cilium pod $pod from $node after agent restart."
    kubectl -n kube-system delete pod "$pod" --grace-period=0 --force --wait=false || true
  fi

  for attempt in $(seq 1 36); do
    if node_ready "$node" && cilium_on_node_healthy "$node"; then
      echo "$node recovered with a healthy Cilium agent."
      return 0
    fi
    wait_progress "Waiting for $node and Cilium to recover" "$attempt" 36
    sleep 5
  done

  echo "$node did not recover within the bounded worker recovery window." >&2
  dump_worker_agent_diagnostics "$ansible_host" "$node"
  return 1
}

recycle_cilium_on_node() {
  local node="$1" pod attempt
  pod="$(kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || return 1

  echo "Node $node is reachable but Cilium is unhealthy. Recycling $pod."
  kubectl -n kube-system delete pod "$pod" --grace-period=0 --force --wait=false || true
  for attempt in $(seq 1 36); do
    if node_ready "$node" && cilium_on_node_healthy "$node"; then
      echo "$node recovered with a fresh Cilium pod."
      return 0
    fi
    wait_progress "Waiting for Cilium recovery on $node" "$attempt" 36
    sleep 5
  done
  return 1
}

repair_not_ready_nodes() {
  local nodes node ready_status ready_reason ansible_host
  mapfile -t nodes < <(
    kubectl get nodes -o json \
      | jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status != "True")) | .metadata.name'
  )

  [ "${#nodes[@]}" -gt 0 ] || return 0

  echo "Detected non-ready nodes: ${nodes[*]}"
  kubectl get nodes -o wide >&2 || true

  for node in "${nodes[@]}"; do
    read -r ready_status ready_reason < <(
      kubectl get node "$node" -o json \
        | jq -r '[.status.conditions[]? | select(.type == "Ready")][0] | [.status, .reason] | @tsv'
    )

    if [ "$ready_status" = "Unknown" ] || [ "$ready_reason" = "NodeStatusUnknown" ]; then
      if ! restart_worker_agent "$node"; then
        return 1
      fi
      continue
    fi

    if kubectl -n kube-system get daemonset/cilium >/dev/null 2>&1; then
      if recycle_cilium_on_node "$node"; then
        continue
      fi
    fi

    ansible_host="$(ansible_host_for_node "$node" || true)"
    if [ -n "$ansible_host" ]; then
      dump_worker_agent_diagnostics "$ansible_host" "$node"
    else
      kubectl describe node "$node" >&2 || true
    fi
    return 1
  done

  all_nodes_ready
}

cluster_reused=false
if fetch_existing_kubeconfig && existing_cluster_matches; then
  cluster_reused=true
  progress 55 "Reusing existing K3s cluster without restarting healthy nodes"
  echo "Existing K3s $DESIRED_K3S_VERSION cluster detected with $EXPECTED_NODE_COUNT nodes."
else
  progress 55 "Installing and configuring K3s cluster"
  "$ROOT/.deploy-venv/bin/ansible-playbook" \
    -i "$GENERATED/inventory.ini" \
    "$ROOT/infrastructure/ansible/playbooks/cluster.yml"

  progress 65 "Fetching hardened kubeconfig"
  "$ROOT/scripts/fetch-kubeconfig.sh"
fi

if [ "$cluster_reused" = true ]; then
  progress 65 "Using hardened kubeconfig from existing cluster"
fi

if [ ! -s "$KUBECONFIG" ]; then
  echo "Kubeconfig was not generated at $KUBECONFIG" >&2
  exit 1
fi
kubectl cluster-info >/dev/null

# Reuse a matching cluster instead of reinstalling K3s on every deployment.
# When a worker has stopped posting status, repair its k3s-agent over SSH first;
# only use a Cilium recycle for a node whose kubelet is still reachable.
repair_not_ready_nodes

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
