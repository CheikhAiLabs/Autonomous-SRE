#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED="$ROOT/.generated"
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
  set +e
  "$ROOT/scripts/deploy-ci.sh"
  local rc=$?
  set -e
  return "$rc"
}

first_rc=0
run_deploy || first_rc=$?
if [ "$first_rc" -eq 0 ]; then
  exit 0
fi

echo "Initial deployment attempt failed. Checking whether the failure is caused by an unreachable worker."

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
  echo "The deployment failure is not an unreachable-worker condition; preserving the original failure." >&2
  exit "$first_rc"
fi

for node in "${stale_workers[@]}"; do
  recover_stale_worker "$node"
done

echo "Recovered stale worker nodes. Retrying the idempotent production deployment once."
"$ROOT/scripts/deploy-ci.sh"
