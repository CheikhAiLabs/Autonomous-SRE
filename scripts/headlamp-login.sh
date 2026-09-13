#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
LOCAL_URL="http://127.0.0.1:4466/kubernetes/"

TOKEN="$(kubectl --kubeconfig="$KUBECONFIG_PATH" -n sre-system create token headlamp --duration=24h)"

if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$TOKEN" | pbcopy
  echo "Headlamp token copied to clipboard (valid for 24h)."
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$TOKEN" | xclip -selection clipboard
  echo "Headlamp token copied to clipboard (valid for 24h)."
else
  echo "Headlamp token (valid for 24h):"
  printf '%s\n' "$TOKEN"
fi

echo "Opening Headlamp locally at $LOCAL_URL"
echo "Keep this terminal open while using Headlamp."

kubectl --kubeconfig="$KUBECONFIG_PATH" -n sre-system port-forward service/headlamp 4466:80 >/tmp/autonomous-sre-headlamp-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:4466/kubernetes/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    cat /tmp/autonomous-sre-headlamp-port-forward.log >&2 || true
    exit 1
  fi
  sleep 1
done

if command -v open >/dev/null 2>&1; then
  open "$LOCAL_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$LOCAL_URL" >/dev/null 2>&1 || true
fi

wait "$PF_PID"
