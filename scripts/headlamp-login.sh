#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
FQDN="$(cat "$ROOT/.generated/platform-fqdn" 2>/dev/null || true)"

if [ -z "$FQDN" ]; then
  echo "Platform FQDN is unavailable. Run make deploy or fetch the generated deployment state first." >&2
  exit 1
fi

URL="https://$FQDN/kubernetes/"
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

echo "Opening Headlamp at $URL"
echo "Paste the token if Headlamp asks you to authenticate."

reachable=false
for attempt in $(seq 1 20); do
  if curl -fsSL --max-time 10 "$URL" >/dev/null 2>&1; then
    reachable=true
    break
  fi
  sleep 2
done

if [ "$reachable" != true ]; then
  echo "Headlamp is not reachable through the public Gateway at $URL" >&2
  echo "Check the Gateway and HTTPRoute before retrying." >&2
  exit 1
fi

if command -v open >/dev/null 2>&1; then
  open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
else
  printf '%s\n' "$URL"
fi
