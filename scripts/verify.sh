#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"

pass() { printf '  %-34s ✓\n' "$1"; }
fail() { printf '  %-34s ✗\n' "$1"; exit 1; }

kubectl wait --for=condition=Ready nodes --all --timeout=3m >/dev/null && pass "Kubernetes nodes" || fail "Kubernetes nodes"
kubectl -n kube-system rollout status daemonset/cilium --timeout=2m >/dev/null && pass "Cilium" || fail "Cilium"
kubectl -n sre-system rollout status statefulset/postgres --timeout=3m >/dev/null && pass "PostgreSQL" || fail "PostgreSQL"
kubectl -n sre-system rollout status deployment/opa --timeout=2m >/dev/null && pass "OPA" || fail "OPA"
kubectl -n sre-system rollout status deployment/autonomous-sre-api --timeout=4m >/dev/null && pass "SRE API" || fail "SRE API"
kubectl -n sre-system rollout status deployment/autonomous-sre-worker --timeout=4m >/dev/null && pass "Incident worker" || fail "Incident worker"
kubectl -n sre-system rollout status deployment/remediation-controller --timeout=4m >/dev/null && pass "Remediation controller" || fail "Remediation controller"
kubectl -n sre-system rollout status deployment/autonomous-sre-dashboard --timeout=4m >/dev/null && pass "Dashboard" || fail "Dashboard"
kubectl -n demo rollout status deployment/demo-service --timeout=3m >/dev/null && pass "Demo workload" || fail "Demo workload"

kubectl get --raw '/api/v1/namespaces/sre-system/services/http:autonomous-sre-api:8000/proxy/healthz' | grep -q 'ok' && pass "API health endpoint" || fail "API health endpoint"
kubectl get --raw '/api/v1/namespaces/demo/services/http:demo-service:8080/proxy/healthz' | grep -q 'ok' && pass "Demo health endpoint" || fail "Demo health endpoint"

kubectl -n sre-system exec deployment/ollama -- ollama list >/dev/null && pass "Local Ollama runtime" || fail "Local Ollama runtime"

if kubectl -n sre-system wait certificate/autonomous-sre --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
  pass "Let's Encrypt certificate"
else
  echo "  Certificate is not Ready yet; inspect with: kubectl -n sre-system describe certificate autonomous-sre"
fi

FQDN="$(cat "$ROOT/.generated/platform-fqdn" 2>/dev/null || true)"
[ -n "$FQDN" ] && echo "Dashboard: https://$FQDN"
