#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
export KUBECONFIG="${KUBECONFIG:-$GENERATED/kubeconfig}"

for cmd in kubectl helm tofu jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing deployment tool: $cmd" >&2; exit 1; }
done

[ -s "$KUBECONFIG" ] || { echo "Kubeconfig is not available at $KUBECONFIG" >&2; exit 1; }
kubectl cluster-info >/dev/null

"$ROOT/scripts/bootstrap-state.sh" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init \
  -input=false \
  -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
CP_PRIVATE="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_private_ip)"

cilium_live_healthy() {
  local expected pods
  expected="$(kubectl get nodes -l kubernetes.io/os=linux -o json | jq '.items | length')"
  pods="$(kubectl -n kube-system get pods -l k8s-app=cilium -o json 2>/dev/null || printf '{"items":[]}')"

  jq -e --argjson expected "$expected" '
    (.items | length) == $expected and
    $expected > 0 and
    all(.items[];
      .metadata.deletionTimestamp == null and
      .status.phase == "Running" and
      ((.status.containerStatuses // []) | length) > 0 and
      all((.status.containerStatuses // [])[]; .ready == true)
    )
  ' >/dev/null <<<"$pods"
}

if cilium_live_healthy; then
  echo "Cilium is already healthy on every Linux node."
  exit 0
fi

echo "Cilium is missing or unhealthy. Reconciling the cluster network before retrying production deployment."
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

status="$(helm status cilium --namespace kube-system -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
case "$status" in
  pending-install|pending-upgrade|pending-rollback|failed)
    echo "Removing unusable Cilium Helm release state: ${status}."
    helm uninstall cilium --namespace kube-system --wait --timeout 5m || true
    ;;
esac

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.20.1 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$CP_PRIVATE" \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set operator.replicas=1 \
  --wait \
  --timeout 10m

kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

if ! cilium_live_healthy; then
  echo "Cilium reconciliation completed but live health is still not good on every node." >&2
  kubectl get nodes -o wide >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 || true
  exit 1
fi

echo "Cilium networking recovered and all Kubernetes nodes are Ready."
