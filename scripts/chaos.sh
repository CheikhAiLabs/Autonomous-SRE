#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
SCENARIO="${1:-}"

case "$SCENARIO" in
  pod-kill)
    echo "Kubernetes self-heal sanity check: no Autonomous-SRE incident is expected unless recovery is abnormally slow."
    POD="$(kubectl -n demo get pod -l app=demo-service -o jsonpath='{.items[0].metadata.name}')"
    echo "Deleting one controller-owned demo Pod: $POD"
    kubectl -n demo delete pod "$POD"
    kubectl -n demo rollout status deployment/demo-service --timeout=2m
    ;;
  replica-floor)
    echo "Introducing a sustained production replica-floor violation..."
    kubectl -n demo scale deployment/demo-service --replicas=1
    kubectl -n demo rollout status deployment/demo-service --timeout=2m
    echo "Waiting for Autonomous-SRE to restore the required replica count..."
    recovered=false
    for _ in $(seq 1 90); do
      DESIRED="$(kubectl -n demo get deploy demo-service -o jsonpath='{.spec.replicas}')"
      READY="$(kubectl -n demo get deploy demo-service -o jsonpath='{.status.readyReplicas}')"
      READY="${READY:-0}"
      if [ "$DESIRED" = "2" ] && [ "$READY" = "2" ]; then
        recovered=true
        break
      fi
      sleep 5
    done
    if [ "$recovered" = true ]; then
      echo "✓ Autonomous replica-floor remediation observed"
    else
      echo "✗ Autonomous replica-floor remediation was not observed within timeout" >&2
      kubectl -n demo scale deployment/demo-service --replicas=2 >/dev/null || true
      exit 1
    fi
    ;;
  bad-release)
    echo "Starting in-cluster traffic generator..."
    kubectl -n demo delete pod sre-loadgen --ignore-not-found >/dev/null
    kubectl -n demo run sre-loadgen \
      --image=curlimages/curl:8.17.0 \
      --restart=Never \
      --command -- sh -c 'while true; do curl -fsS http://demo-service:8080/ >/dev/null || true; sleep 0.1; done'
    kubectl -n demo wait --for=condition=Ready pod/sre-loadgen --timeout=90s

    echo "Introducing bad release: ERROR_RATE=0.85"
    kubectl -n demo set env deployment/demo-service ERROR_RATE=0.85
    kubectl -n demo rollout status deployment/demo-service --timeout=2m

    echo "Waiting for Autonomous-SRE to restore the previous revision..."
    recovered=false
    for _ in $(seq 1 90); do
      VALUE="$(kubectl -n demo get deploy demo-service -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ERROR_RATE")].value}')"
      if [ "$VALUE" = "0" ]; then
        recovered=true
        break
      fi
      sleep 5
    done
    kubectl -n demo delete pod sre-loadgen --ignore-not-found >/dev/null
    if [ "$recovered" = true ]; then
      echo "✓ Autonomous rollback observed"
    else
      echo "✗ Autonomous rollback was not observed within timeout" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {pod-kill|replica-floor|bad-release}" >&2
    exit 2
    ;;
esac
