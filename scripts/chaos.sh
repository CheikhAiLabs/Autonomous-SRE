#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
SCENARIO="${1:-}"
SCENARIO_OK=false
LOADGEN_STARTED=false

prometheus_alert_state() {
  local alert_name="$1"
  kubectl get --raw '/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts' 2>/dev/null \
    | jq -r --arg name "$alert_name" '[.data.alerts[]? | select(.labels.alertname == $name) | .state][0] // "inactive"' \
    || printf 'unavailable\n'
}

latest_incident_snapshot() {
  local alert_name="$1"
  kubectl get --raw '/api/v1/namespaces/sre-system/services/http:autonomous-sre-api:8000/proxy/api/v1/incidents' 2>/dev/null \
    | jq -r --arg name "$alert_name" '
        [ .[] | select(.evidence.alert_name == $name) ][0] as $i
        | if $i == null then "none"
          else (($i.status // "unknown") + "/" + ($i.plan.action // "no-plan") + "/" + ($i.id // "unknown"))
          end
      ' \
    || printf 'unavailable\n'
}

print_incident_report_status() {
  local alert_name="$1" snapshot incident_id report
  snapshot="$(latest_incident_snapshot "$alert_name")"
  incident_id="$(printf '%s' "$snapshot" | awk -F/ '{print $3}')"
  if [ -z "$incident_id" ] || [ "$incident_id" = "unknown" ] || [ "$snapshot" = "none" ] || [ "$snapshot" = "unavailable" ]; then
    return 0
  fi

  sleep 2
  report="$(kubectl get --raw "/api/v1/namespaces/sre-system/services/http:autonomous-sre-api:8000/proxy/api/v1/incidents/${incident_id}/report" 2>/dev/null || true)"
  if [ -n "$report" ]; then
    printf '  incident=%s, email=%s\n' \
      "$(printf '%s' "$report" | jq -r '.status // "unknown"')" \
      "$(printf '%s' "$report" | jq -r '.email_delivery.status // "unknown"')"
  fi
}

print_pipeline_diagnostics() {
  local alert_name="$1"
  echo >&2
  echo "Autonomous-SRE diagnostics:" >&2
  echo "  prometheus_alert=$(prometheus_alert_state "$alert_name")" >&2
  echo "  latest_incident=$(latest_incident_snapshot "$alert_name")" >&2
  echo "  worker tail:" >&2
  kubectl -n sre-system logs deployment/autonomous-sre-worker --tail=120 >&2 || true
  echo "  controller tail:" >&2
  kubectl -n sre-system logs deployment/remediation-controller --tail=120 >&2 || true
}

cleanup() {
  case "$SCENARIO" in
    replica-floor)
      if [ "$SCENARIO_OK" != true ]; then
        echo "Restoring demo-service replica floor after interrupted/failed chaos run..." >&2
        kubectl -n demo scale deployment/demo-service --replicas=2 >/dev/null 2>&1 || true
      fi
      ;;
    bad-release)
      if [ "$LOADGEN_STARTED" = true ]; then
        kubectl -n demo delete pod sre-loadgen --ignore-not-found >/dev/null 2>&1 || true
      fi
      if [ "$SCENARIO_OK" != true ]; then
        echo "Restoring demo-service ERROR_RATE after interrupted/failed chaos run..." >&2
        kubectl -n demo set env deployment/demo-service ERROR_RATE=0 >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$SCENARIO" in
  pod-kill)
    echo "Kubernetes self-heal sanity check: no Autonomous-SRE incident is expected unless recovery is abnormally slow."
    POD="$(kubectl -n demo get pod -l app=demo-service -o jsonpath='{.items[0].metadata.name}')"
    echo "Deleting one controller-owned demo Pod: $POD"
    kubectl -n demo delete pod "$POD"
    kubectl -n demo rollout status deployment/demo-service --timeout=2m
    SCENARIO_OK=true
    ;;
  replica-floor)
    ALERT_NAME="DemoServiceReplicaFloorBreached"
    echo "Introducing a sustained production replica-floor violation..."
    kubectl -n demo scale deployment/demo-service --replicas=1
    kubectl -n demo rollout status deployment/demo-service --timeout=2m
    echo "Waiting for Autonomous-SRE to restore the required replica count..."
    echo "The alert requires 30s of sustained violation before it can fire; the worker then polls every 15s."
    recovered=false
    for attempt in $(seq 1 90); do
      DESIRED="$(kubectl -n demo get deploy demo-service -o jsonpath='{.spec.replicas}')"
      READY="$(kubectl -n demo get deploy demo-service -o jsonpath='{.status.readyReplicas}')"
      READY="${READY:-0}"
      if [ "$DESIRED" = "2" ] && [ "$READY" = "2" ]; then
        recovered=true
        break
      fi
      if [ $((attempt % 3)) -eq 0 ]; then
        ELAPSED=$((attempt * 5))
        echo "  ${ELAPSED}s elapsed: desired=${DESIRED}, ready=${READY}, alert=$(prometheus_alert_state "$ALERT_NAME"), incident=$(latest_incident_snapshot "$ALERT_NAME")"
      fi
      sleep 5
    done
    if [ "$recovered" = true ]; then
      SCENARIO_OK=true
      echo "✓ Autonomous replica-floor remediation observed"
      print_incident_report_status "$ALERT_NAME"
    else
      echo "✗ Autonomous replica-floor remediation was not observed within timeout" >&2
      print_pipeline_diagnostics "$ALERT_NAME"
      exit 1
    fi
    ;;
  bad-release)
    ALERT_NAME="DemoServiceHigh5xxRate"
    echo "Starting in-cluster traffic generator..."
    kubectl -n demo delete pod sre-loadgen --ignore-not-found >/dev/null
    kubectl -n demo run sre-loadgen \
      --image=curlimages/curl:8.17.0 \
      --restart=Never \
      --command -- sh -c 'while true; do curl -fsS http://demo-service:8080/ >/dev/null || true; sleep 0.1; done'
    LOADGEN_STARTED=true
    kubectl -n demo wait --for=condition=Ready pod/sre-loadgen --timeout=90s

    echo "Introducing bad release: ERROR_RATE=0.85"
    kubectl -n demo set env deployment/demo-service ERROR_RATE=0.85
    kubectl -n demo rollout status deployment/demo-service --timeout=2m

    echo "Waiting for Autonomous-SRE to restore the previous revision..."
    echo "The high-5xx alert must remain above 20% for 20s. Local AI reasoning is bounded to 30s before deterministic fallback."
    recovered=false
    for attempt in $(seq 1 90); do
      VALUE="$(kubectl -n demo get deploy demo-service -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ERROR_RATE")].value}')"
      if [ "$VALUE" = "0" ]; then
        recovered=true
        break
      fi
      if [ $((attempt % 3)) -eq 0 ]; then
        ELAPSED=$((attempt * 5))
        echo "  ${ELAPSED}s elapsed: ERROR_RATE=${VALUE:-unset}, alert=$(prometheus_alert_state "$ALERT_NAME"), incident=$(latest_incident_snapshot "$ALERT_NAME")"
      fi
      sleep 5
    done
    if [ "$recovered" = true ]; then
      SCENARIO_OK=true
      echo "✓ Autonomous rollback observed"
      print_incident_report_status "$ALERT_NAME"
    else
      echo "✗ Autonomous rollback was not observed within timeout" >&2
      print_pipeline_diagnostics "$ALERT_NAME"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {pod-kill|replica-floor|bad-release}" >&2
    exit 2
    ;;
esac
