#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"

pass() { printf '  %-34s ✓\n' "$1"; }
fail() { printf '  %-34s ✗\n' "$1"; exit 1; }

diagnose_workload() {
  namespace="$1"
  resource="$2"
  selector="$3"

  echo
  echo "Diagnostics for $namespace/$resource:"
  kubectl -n "$namespace" get "$resource" -o wide || true
  kubectl -n "$namespace" get pods -l "$selector" -o wide || true
  kubectl -n "$namespace" describe "$resource" || true
  kubectl -n "$namespace" describe pods -l "$selector" || true
  echo "Current container logs:"
  kubectl -n "$namespace" logs -l "$selector" --all-containers=true --tail=200 || true
  echo "Previous container logs:"
  for pod in $(kubectl -n "$namespace" get pods -l "$selector" -o name 2>/dev/null); do
    kubectl -n "$namespace" logs "$pod" --all-containers=true --previous --tail=200 || true
  done
  kubectl -n "$namespace" get events --sort-by=.lastTimestamp | tail -n 50 || true
}

cilium_live_healthy() {
  local nodes node
  nodes=()
  while IFS= read -r node; do
    [ -n "$node" ] && nodes+=("$node")
  done < <(kubectl get nodes -l kubernetes.io/os=linux -o json | jq -r '.items[].metadata.name')
  [ "${#nodes[@]}" -gt 0 ] || return 1

  for node in "${nodes[@]}"; do
    kubectl -n kube-system get pods -l k8s-app=cilium \
      --field-selector "spec.nodeName=$node" -o json 2>/dev/null \
      | jq -e '
          (.items | length) == 1 and
          .items[0].metadata.deletionTimestamp == null and
          .items[0].status.phase == "Running" and
          ((.items[0].status.containerStatuses // []) | length) > 0 and
          all((.items[0].status.containerStatuses // [])[]; .ready == true)
        ' >/dev/null || return 1
  done
}

kubectl wait --for=condition=Ready nodes --all --timeout=3m >/dev/null && pass "Kubernetes nodes" || fail "Kubernetes nodes"

IMAGE_PULL_FAILURES="$(
  kubectl get pods -A -o json | jq -r '
    .items[] as $pod
    | $pod.status.containerStatuses[]?
    | select((.state.waiting.reason // "") | test("ImagePull|ErrImagePull|CrashLoopBackOff"))
    | "\($pod.metadata.namespace)/\($pod.metadata.name) \(.name): \(.state.waiting.reason)"
  '
)"
if [ -n "$IMAGE_PULL_FAILURES" ]; then
  echo "$IMAGE_PULL_FAILURES" >&2

  if printf '%s\n' "$IMAGE_PULL_FAILURES" | grep -q '^sre-system/remediation-controller-'; then
    diagnose_workload \
      "sre-system" \
      "deployment/remediation-controller" \
      "app.kubernetes.io/name=remediation-controller"
  fi

  fail "Container startup health"
else
  pass "Container startup health"
fi

if cilium_live_healthy; then
  pass "Cilium"
else
  kubectl -n kube-system get daemonset/cilium -o wide >&2 || true
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 || true
  fail "Cilium"
fi
kubectl -n sre-system rollout status statefulset/postgres --timeout=3m >/dev/null && pass "PostgreSQL" || fail "PostgreSQL"
if kubectl -n sre-system rollout status deployment/opa --timeout=2m >/dev/null; then
  pass "OPA"
else
  diagnose_workload "sre-system" "deployment/opa" "app=opa"
  fail "OPA"
fi
kubectl -n sre-system rollout status deployment/autonomous-sre-api --timeout=4m >/dev/null && pass "SRE API" || fail "SRE API"
kubectl -n sre-system rollout status deployment/autonomous-sre-worker --timeout=4m >/dev/null && pass "Incident worker" || fail "Incident worker"
if kubectl -n sre-system rollout status deployment/remediation-controller --timeout=4m >/dev/null; then
  pass "Remediation controller"
else
  diagnose_workload \
    "sre-system" \
    "deployment/remediation-controller" \
    "app.kubernetes.io/name=remediation-controller"
  fail "Remediation controller"
fi
kubectl -n sre-system rollout status deployment/headlamp --timeout=4m >/dev/null && pass "Kubernetes Explorer" || fail "Kubernetes Explorer"
kubectl -n sre-system rollout status deployment/autonomous-sre-dashboard --timeout=4m >/dev/null && pass "Dashboard" || fail "Dashboard"
kubectl -n demo rollout status deployment/demo-service --timeout=3m >/dev/null && pass "Demo workload" || fail "Demo workload"

kubectl get --raw '/api/v1/namespaces/sre-system/services/http:autonomous-sre-api:8000/proxy/healthz' | grep -q 'ok' && pass "API health endpoint" || fail "API health endpoint"
kubectl get --raw '/api/v1/namespaces/demo/services/http:demo-service:8080/proxy/healthz' | grep -q 'ok' && pass "Demo health endpoint" || fail "Demo health endpoint"

AGENTS_JSON="$(kubectl get --raw '/api/v1/namespaces/sre-system/services/http:autonomous-sre-api:8000/proxy/api/v1/agents')"
if printf '%s' "$AGENTS_JSON" | python3 -c '
import json
import sys
from datetime import UTC, datetime, timedelta

items = {item["name"]: item for item in json.load(sys.stdin)}
cutoff = datetime.now(UTC) - timedelta(seconds=60)
required = ("remediation-controller", "recovery-verifier")

def fresh(name):
    item = items.get(name)
    if not item or not item.get("updated_at"):
        return False
    updated = datetime.fromisoformat(item["updated_at"].replace("Z", "+00:00"))
    return updated >= cutoff and (item.get("details") or {}).get("heartbeat") == "healthy"

raise SystemExit(0 if all(fresh(name) for name in required) else 1)
'; then
  pass "Remediation control-plane heartbeat"
else
  echo "Remediation controller/verifier did not report a fresh heartbeat in the last 60 seconds." >&2
  echo "$AGENTS_JSON" | jq -c '.[] | select(.name == "remediation-controller" or .name == "recovery-verifier")' >&2 || true
  diagnose_workload \
    "sre-system" \
    "deployment/remediation-controller" \
    "app.kubernetes.io/name=remediation-controller"
  fail "Remediation control-plane heartbeat"
fi

kubectl -n sre-system exec deployment/ollama -- ollama list >/dev/null && pass "Local Ollama runtime" || fail "Local Ollama runtime"

if kubectl -n sre-system wait certificate/autonomous-sre --for=condition=Ready --timeout=5m >/dev/null 2>&1; then
  pass "Let's Encrypt certificate"
else
  echo "Certificate is not Ready." >&2
  kubectl -n sre-system describe certificate autonomous-sre >&2 || true
  fail "Let's Encrypt certificate"
fi

FQDN="$(cat "$ROOT/.generated/platform-fqdn" 2>/dev/null || true)"
if [ -z "$FQDN" ]; then
  echo "Platform FQDN is unavailable." >&2
  fail "Public application routes"
fi

if curl -fsSL --retry 12 --retry-all-errors --retry-delay 5 --max-time 15 "https://$FQDN/" >/dev/null; then
  pass "Public dashboard route"
else
  echo "Public dashboard is not reachable at https://$FQDN/" >&2
  kubectl -n sre-system get gateway,httproute -o wide >&2 || true
  fail "Public dashboard route"
fi

if curl -fsSL --retry 12 --retry-all-errors --retry-delay 5 --max-time 15 "https://$FQDN/kubernetes/" >/dev/null; then
  pass "Public Headlamp route"
else
  echo "Headlamp is not reachable at https://$FQDN/kubernetes/" >&2
  kubectl -n sre-system get service/headlamp,endpoints/headlamp -o wide >&2 || true
  kubectl -n sre-system get gateway,httproute -o wide >&2 || true
  fail "Public Headlamp route"
fi

echo "Dashboard: https://$FQDN"
echo "Kubernetes Explorer: https://$FQDN/kubernetes/"
