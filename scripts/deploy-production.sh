#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
export KUBECONFIG="${KUBECONFIG:-$GENERATED/kubeconfig}"

node_ready() {
  local node="$1"
  kubectl get node "$node" -o json 2>/dev/null \
    | jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
}

cilium_ready() {
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

recover_stale_worker() {
  local node="$1" ansible_host attempt
  ansible_host="$(ansible_host_for_node "$node")"
  if [ -z "$ansible_host" ]; then
    echo "Could not map stale Kubernetes node $node to the Ansible inventory." >&2
    return 1
  fi

  echo "Worker $node has stopped reporting to Kubernetes. Performing a controlled host reboot on $ansible_host."
  timeout 30s "$ROOT/.deploy-venv/bin/ansible" "$ansible_host" \
    -i "$GENERATED/inventory.ini" \
    -T 10 \
    -m ansible.builtin.shell \
    -a 'systemctl status k3s-agent --no-pager -l || true; echo "--- k3s-agent journal ---"; journalctl -u k3s-agent -n 120 --no-pager || true' \
    || true

  if ! timeout 480s "$ROOT/.deploy-venv/bin/ansible" "$ansible_host" \
    -i "$GENERATED/inventory.ini" \
    -T 10 \
    -m ansible.builtin.reboot \
    -a 'reboot_timeout=420 connect_timeout=10 post_reboot_delay=15'; then
    echo "Ansible reboot did not complete cleanly. Scheduling a forced reboot as fallback." >&2
    timeout 20s "$ROOT/.deploy-venv/bin/ansible" "$ansible_host" \
      -i "$GENERATED/inventory.ini" \
      -T 10 \
      -m ansible.builtin.shell \
      -a 'nohup sh -c "sleep 2; systemctl reboot --force --force" >/dev/null 2>&1 &' \
      || true
  fi

  for attempt in $(seq 1 120); do
    if node_ready "$node" && cilium_ready "$node"; then
      echo "$node recovered after host reboot and its Cilium agent is healthy."
      return 0
    fi
    if [ "$attempt" -eq 1 ] || [ "$attempt" -eq 120 ] || [ $((attempt % 10)) -eq 0 ]; then
      echo "[WAIT] Waiting for $node after host reboot [$attempt/120]"
    fi
    sleep 5
  done

  echo "$node did not recover after the controlled host reboot." >&2
  kubectl get nodes -o wide >&2 || true
  kubectl describe node "$node" >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 || true
  return 1
}

run_deploy() {
  local log_file="$1" rc
  mkdir -p "$GENERATED"
  set +e
  "$ROOT/scripts/deploy-ci.sh" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

recover_stale_tofu_lock() {
  local log_file="$1" lock_id lock_who runner_host

  if ! grep -q 'Error acquiring the state lock' "$log_file"; then
    return 1
  fi

  lock_id="$(grep -Eo 'ID:[[:space:]]+[0-9a-fA-F-]+' "$log_file" | head -n1 | awk '{print $2}' || true)"
  lock_who="$(grep -Eo 'Who:[[:space:]]+[^[:space:]]+' "$log_file" | head -n1 | awk '{print $2}' || true)"
  runner_host="actions@$(hostname -s)"

  if [ -z "$lock_id" ]; then
    echo "OpenTofu reported a state lock but its lock ID could not be extracted." >&2
    return 1
  fi

  if [ -z "$lock_who" ] || [ "$lock_who" != "$runner_host" ]; then
    echo "Refusing to unlock state owned by ${lock_who:-unknown}; expected $runner_host." >&2
    return 1
  fi

  if pgrep -af '[t]ofu.*apply' >/dev/null 2>&1; then
    echo "An OpenTofu apply process is still running on this deployment runner; refusing to force-unlock." >&2
    return 1
  fi

  echo "Detected stale OpenTofu lock $lock_id left by a cancelled deployment on this runner."
  echo "No apply process is active. Releasing the stale lock before one bounded retry."
  tofu -chdir="$ROOT/infrastructure/opentofu-platform" force-unlock -force "$lock_id"
}

recover_missing_cni() {
  local log_file="$1"

  [ -s "$KUBECONFIG" ] || return 1
  if ! grep -Eq 'NetworkPluginNotReady|cni plugin not initialized|container runtime network not ready' "$log_file"; then
    return 1
  fi

  echo "Detected a K3s cluster blocked before Cilium initialization."
  echo "Reconciling Cilium first, then retrying the idempotent production deployment."
  "$ROOT/scripts/ensure-cilium-network.sh"
}

DEPLOY_LOG="$GENERATED/deploy-ci.log"
LAST_DEPLOY_LOG="$DEPLOY_LOG"
first_rc=0
run_deploy "$DEPLOY_LOG" || first_rc=$?
if [ "$first_rc" -eq 0 ]; then
  exit 0
fi

if recover_stale_tofu_lock "$DEPLOY_LOG"; then
  echo "Stale OpenTofu lock released. Retrying the production deployment once."
  LAST_DEPLOY_LOG="$GENERATED/deploy-ci-after-unlock.log"
  retry_rc=0
  run_deploy "$LAST_DEPLOY_LOG" || retry_rc=$?
  if [ "$retry_rc" -eq 0 ]; then
    exit 0
  fi
  first_rc=$retry_rc
fi

if recover_missing_cni "$LAST_DEPLOY_LOG"; then
  LAST_DEPLOY_LOG="$GENERATED/deploy-ci-after-cni-recovery.log"
  retry_rc=0
  run_deploy "$LAST_DEPLOY_LOG" || retry_rc=$?
  if [ "$retry_rc" -eq 0 ]; then
    exit 0
  fi
  first_rc=$retry_rc
fi

echo "Deployment still failed after bounded automatic recovery. Checking for an unreachable worker."

if [ ! -s "$KUBECONFIG" ] || [ ! -s "$GENERATED/inventory.ini" ]; then
  echo "Deployment failed before Kubernetes recovery data was available; not retrying blindly." >&2
  exit "$first_rc"
fi

mapfile -t stale_workers < <(
  kubectl get nodes -o json 2>/dev/null \
    | jq -r '
        .items[]
        | select((.metadata.labels["node-role.kubernetes.io/control-plane"] // "") == "")
        | select(any(.status.conditions[]?;
            .type == "Ready" and
            (.status == "Unknown" or .reason == "NodeStatusUnknown")))
        | .metadata.name
      '
)

if [ "${#stale_workers[@]}" -eq 0 ]; then
  echo "The remaining deployment failure is not an unreachable-worker condition; preserving the original failure." >&2
  exit "$first_rc"
fi

for node in "${stale_workers[@]}"; do
  recover_stale_worker "$node"
done

echo "Recovered stale worker nodes. Retrying the idempotent production deployment once."
"$ROOT/scripts/deploy-ci.sh"
