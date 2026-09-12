#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ENV="$ROOT/config/project.env"
SECRETS_ENV="$ROOT/config/secrets.env"

for cmd in scw gh tofu jq curl ssh-keygen openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

mkdir -p "$ROOT/.generated"
[ -f "$PROJECT_ENV" ] || cp "$ROOT/config/project.env.example" "$PROJECT_ENV"
[ -f "$SECRETS_ENV" ] || cp "$ROOT/config/secrets.env.example" "$SECRETS_ENV"
chmod 600 "$SECRETS_ENV"

set_kv() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PYI'
from pathlib import Path
import sys
path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines()
out=[]; found=False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={value}"); found=True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PYI
}

# shellcheck disable=SC1090
source "$PROJECT_ENV"
# shellcheck disable=SC1090
source "$SECRETS_ENV"

if [ -z "${SCW_PROJECT_ID:-}" ]; then
  SCW_PROJECT_ID="$(scw config get default-project-id 2>/dev/null || true)"
  [ -n "$SCW_PROJECT_ID" ] || { echo "No Scaleway Project ID found. Run scw login or set SCW_PROJECT_ID." >&2; exit 1; }
  set_kv "$PROJECT_ENV" SCW_PROJECT_ID "$SCW_PROJECT_ID"
fi

if [ "${OPERATOR_CIDR:-auto}" = "auto" ] || [ -z "${OPERATOR_CIDR:-}" ]; then
  IP="$(curl -fsS https://api.ipify.org)"
  OPERATOR_CIDR="${IP}/32"
  set_kv "$PROJECT_ENV" OPERATOR_CIDR "$OPERATOR_CIDR"
fi

if REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" && [ -n "$REPO" ]; then
  GITHUB_REPOSITORY="$REPO"
  set_kv "$PROJECT_ENV" GITHUB_REPOSITORY "$GITHUB_REPOSITORY"
fi

if [ -z "${APPROVAL_SIGNING_KEY:-}" ]; then
  set_kv "$SECRETS_ENV" APPROVAL_SIGNING_KEY "$(openssl rand -hex 32)"
fi
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  set_kv "$SECRETS_ENV" POSTGRES_PASSWORD "$(openssl rand -hex 24)"
fi

# Refresh values after generation.
# shellcheck disable=SC1090
source "$PROJECT_ENV"
# shellcheck disable=SC1090
source "$SECRETS_ENV"

if [ -z "${SMTP_PASSWORD:-}" ] && [ -t 0 ]; then
  echo
  echo "Email alerts are configured for: ${ALERT_EMAIL}"
  echo "For Gmail, enter a Gmail App Password. Leave empty to configure it later."
  read -r -s -p "SMTP password: " SMTP_INPUT || true
  echo
  if [ -n "${SMTP_INPUT:-}" ]; then
    set_kv "$SECRETS_ENV" SMTP_PASSWORD "$SMTP_INPUT"
  fi
fi

echo
echo "Configuration ready"
echo "  Scaleway Project: $SCW_PROJECT_ID"
echo "  Operator CIDR:    $OPERATOR_CIDR"
echo "  Alert email:      $ALERT_EMAIL"
echo "  GitHub repo:      ${GITHUB_REPOSITORY:-not detected}"
echo "  Local secrets:    config/secrets.env (gitignored)"
