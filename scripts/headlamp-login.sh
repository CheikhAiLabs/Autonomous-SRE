#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FQDN="$(cat "$ROOT/.generated/platform-fqdn" 2>/dev/null || true)"

if [ -z "$FQDN" ]; then
  echo "Platform FQDN is unavailable. Run make deploy or fetch the generated deployment state first." >&2
  exit 1
fi

URL="https://$FQDN/kubernetes/"
echo "Opening Headlamp at $URL"

reachable=false
for _ in {1..20}; do
  if curl -fsSL --max-time 10 "$URL" >/dev/null 2>&1; then
    reachable=true
    break
  fi
  sleep 2
done

if [ "$reachable" != true ]; then
  echo "Headlamp is not reachable through the operator-only HTTPS Gateway at $URL" >&2
  echo "Check your current public IP, the Scaleway operator CIDR, Gateway and HTTPRoute." >&2
  exit 1
fi

if command -v open >/dev/null 2>&1; then
  open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 || true
else
  printf '%s\n' "$URL"
fi
