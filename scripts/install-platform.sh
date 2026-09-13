#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
export KUBECONFIG="${KUBECONFIG:-$GENERATED/kubeconfig}"

for cmd in kubectl helm helmfile tofu jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing deployment tool: $cmd" >&2; exit 1; }
done

recover_helm_release() {
  local release="$1"
  local namespace="$2"
  local status last_deployed

  if ! status="$(helm status "$release" --namespace "$namespace" -o json 2>/dev/null | jq -r '.info.status // empty')"; then
    return 0
  fi

  case "$status" in
    pending-install|pending-upgrade|pending-rollback)
      echo "Recovering stale Helm operation for $namespace/$release ($status)"
      last_deployed="$(helm history "$release" --namespace "$namespace" -o json 2>/dev/null \
        | jq -r '[.[] | select(.status == "deployed") | (.revision | tonumber)] | max // empty')"

      if [ -n "$last_deployed" ]; then
        if helm rollback "$release" "$last_deployed" \
          --namespace "$namespace" \
          --wait \
          --timeout 5m \
          --cleanup-on-fail; then
          return 0
        fi
      fi

      echo "Rollback could not clear the stale state; recreating $namespace/$release"
      helm uninstall "$release" --namespace "$namespace" --wait --timeout 5m || true
      ;;
  esac
}

cilium_live_healthy() {
  local expected pods
  expected="$(kubectl get nodes -l kubernetes.io/os=linux -o json | jq '.items | length')"
  pods="$(kubectl -n kube-system get pods -l k8s-app=cilium -o json)"

  jq -e --argjson expected "$expected" '
    (.items | length) == $expected and
    $expected > 0 and
    all(.items[];
      .status.phase == "Running" and
      ((.status.containerStatuses // []) | length) > 0 and
      all((.status.containerStatuses // [])[]; .ready == true)
    )
  ' >/dev/null <<<"$pods"
}

wait_for_cilium_live_health() {
  local attempt
  for attempt in $(seq 1 12); do
    if cilium_live_healthy; then
      echo "Cilium live health is good on every Linux node."
      return 0
    fi
    sleep 5
  done

  echo "Cilium live health check failed." >&2
  kubectl -n kube-system get daemonset/cilium -o wide >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o json \
    | jq -r '.items[] | [.metadata.name, .spec.nodeName, .status.phase, ((.status.containerStatuses // []) | map(.name + ":ready=" + (.ready|tostring)) | join(","))] | @tsv' >&2 || true
  return 1
}

"$ROOT/scripts/bootstrap-state.sh" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
CP_PRIVATE="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_private_ip)"

echo "[platform 1/4] Installing Gateway API and Cilium"
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

CILIUM_STATUS="$(helm status cilium --namespace kube-system -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
CILIUM_CHART="$(helm list --namespace kube-system -f '^cilium$' -o json 2>/dev/null | jq -r '.[0].chart // empty' || true)"

if [ "$CILIUM_STATUS" = "deployed" ] && [ "$CILIUM_CHART" = "cilium-1.20.1" ]; then
  echo "Cilium 1.20.1 is already deployed; preserving the existing dataplane."
else
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
fi

# On this K3s cluster the DaemonSet/Pod Ready condition can remain stale even
# while every Cilium container is actually Running and ready. Validate the live
# container state instead of blocking application deployments on stale status.
wait_for_cilium_live_health
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

echo "[platform 2/4] Installing Prometheus stack and CRDs"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
recover_helm_release kube-prometheus-stack monitoring
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 86.0.1 \
  --values "$ROOT/platform/helmfile/values/kube-prometheus-stack.yaml" \
  --atomic \
  --cleanup-on-fail \
  --timeout 10m
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=2m
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=2m

echo "[platform 3/4] Reconciling remaining Helm releases"
helmfile -f "$ROOT/platform/helmfile/helmfile.yaml" sync --concurrency 1

echo "[platform 4/4] Platform Helm releases reconciled"
