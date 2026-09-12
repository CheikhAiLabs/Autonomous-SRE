#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ENV="$ROOT/config/project.env"
SECRETS_ENV="$ROOT/config/secrets.env"
GENERATED="$ROOT/.generated"
mkdir -p "$GENERATED"

# Automation must never stop in an interactive pager.
export PAGER=cat
export GIT_PAGER=cat
export GH_PAGER=cat
export AWS_PAGER=""
export LESS="-FRX"

progress() {
  local percent="$1"
  shift
  printf '\n[%3d%%] %s\n' "$percent" "$*"
  if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    printf '::notice title=Autonomous-SRE progress::[%d%%] %s\n' "$percent" "$*"
  fi
}

wait_progress() {
  local label="$1"
  local current="$2"
  local total="$3"
  local percent=$(( current * 100 / total ))

  if [ -t 1 ] && [ "${GITHUB_ACTIONS:-false}" != "true" ]; then
    printf '\r%-42s %3d%% [%d/%d]' "$label" "$percent" "$current" "$total"
  elif [ "$current" -eq 1 ] || [ "$current" -eq "$total" ] || [ $((current % 5)) -eq 0 ]; then
    printf '[WAIT] %s %3d%% [%d/%d]\n' "$label" "$percent" "$current" "$total"
  fi
}

load_config() {
  [ -f "$PROJECT_ENV" ] || "$ROOT/scripts/configure.sh"
  # shellcheck disable=SC1090
  source "$PROJECT_ENV"
  # shellcheck disable=SC1090
  source "$SECRETS_ENV"
  export SCW_PROJECT_ID SCW_REGION SCW_ZONE OPERATOR_CIDR ALERT_EMAIL GITHUB_REPOSITORY
  export CONTROL_PLANE_TYPE WORKER_TYPE WORKER_COUNT RUNNER_TYPE AUTO_REMEDIATION_MODE OLLAMA_MODEL
  export SMTP_SMARTHOST SMTP_USERNAME LETSENCRYPT_EMAIL
  export STATE_BUCKET="${STATE_BUCKET:-}"
}

load_scw_credentials() {
  SCW_ACCESS_KEY="${SCW_ACCESS_KEY:-$(scw config get access-key)}"
  SCW_SECRET_KEY="${SCW_SECRET_KEY:-$(scw config get secret-key)}"
  export SCW_ACCESS_KEY SCW_SECRET_KEY
  export SCW_DEFAULT_PROJECT_ID="$SCW_PROJECT_ID"
  export SCW_DEFAULT_REGION="$SCW_REGION"
  export SCW_DEFAULT_ZONE="$SCW_ZONE"
  export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
  export AWS_REGION="$SCW_REGION"
  export AWS_DEFAULT_REGION="$SCW_REGION"
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_PAGER=""
}

require_repo() {
  [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is empty. Configure a GitHub remote first." >&2; exit 1; }
  gh repo view "$GITHUB_REPOSITORY" >/dev/null
}

run_workflow_and_wait() {
  local workflow="$1"
  local previous_id run_id attempt
  previous_id="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  echo "Dispatching $workflow..."
  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref main
  run_id=""
  for attempt in $(seq 1 30); do
    wait_progress "Waiting for $workflow run" "$attempt" 30
    run_id="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    if [ -n "$run_id" ] && [ "$run_id" != "$previous_id" ]; then
      [ -t 1 ] && printf '\n' || true
      break
    fi
    sleep 2
  done
  [ -n "$run_id" ] && [ "$run_id" != "$previous_id" ] || { echo "Could not find new workflow run for $workflow" >&2; exit 1; }
  gh run watch "$run_id" --repo "$GITHUB_REPOSITORY" --exit-status
}
