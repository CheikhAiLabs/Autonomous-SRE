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

"$ROOT/scripts/bootstrap-state.sh" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
CP_PRIVATE="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_private_ip)"

echo "[platform 1/4] Installing Gateway API and Cilium"
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
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
  --set operator.replicas=1

kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

echo "[platform 2/4] Installing Prometheus CRDs before dependent releases"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 86.0.1 \
  --values "$ROOT/platform/helmfile/values/kube-prometheus-stack.yaml" \
  --wait \
  --timeout 10m
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=2m
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=2m

echo "[platform 3/4] Reconciling remaining Helm releases"
helmfile -f "$ROOT/platform/helmfile/helmfile.yaml" sync

echo "[platform 4/4] Platform Helm releases reconciled"
