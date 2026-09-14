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

  if [ -z "${SCW_DEFAULT_ORGANIZATION_ID:-}" ]; then
    SCW_DEFAULT_ORGANIZATION_ID="$(
      curl -fsSL \
        -H "X-Auth-Token: $SCW_SECRET_KEY" \
        -H "Accept: application/json" \
        "https://api.scaleway.com/account/v3/projects/$SCW_PROJECT_ID" \
        | jq -r '.organization_id // .organizationId // empty'
    )"
  fi
  [ -n "$SCW_DEFAULT_ORGANIZATION_ID" ] || {
    echo "Unable to determine Scaleway Organization ID from project $SCW_PROJECT_ID" >&2
    exit 1
  }
  export SCW_DEFAULT_ORGANIZATION_ID

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
  local workflow="$1" request_id attempt run_id
  request_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  echo "Dispatching $workflow (request $request_id)..."
  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref main \
    -f "request_id=$request_id"
  run_id=""
  for attempt in $(seq 1 30); do
    wait_progress "Waiting for $workflow run" "$attempt" 30
    run_id="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
      --branch main --event workflow_dispatch --limit 100 \
      --json databaseId,displayTitle \
      | jq -r --arg request "$request_id" \
        '[.[] | select(.displayTitle | endswith("(" + $request + ")"))][0].databaseId // empty')"
    if [ -n "$run_id" ]; then
      break
    fi
    sleep 2
  done
  [ -n "$run_id" ] || { echo "Could not find $workflow request $request_id" >&2; return 1; }
  gh run watch "$run_id" --repo "$GITHUB_REPOSITORY" --exit-status || return 1
  [ "$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json conclusion --jq .conclusion)" = "success" ] \
    || { echo "$workflow run $run_id did not succeed." >&2; return 1; }
  WORKFLOW_RUN_ID="$run_id"
  WORKFLOW_RUN_SHA="$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json headSha --jq .headSha)"
}

wait_for_production_deployment() {
  local run_id attempt
  : "${WORKFLOW_RUN_ID:?A completed build run is required}"
  : "${WORKFLOW_RUN_SHA:?The completed build commit is required}"
  run_id=""
  for attempt in $(seq 1 60); do
    wait_progress "Waiting for production deployment of build $WORKFLOW_RUN_ID" "$attempt" 60
    # Match the immutable source build ID. The deployment workflow may display
    # the source SHA parsed from the Build Images title while GitHub's own
    # workflow_run head SHA points at the moving default branch.
    run_id="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow deploy.yml \
      --branch main --event workflow_run --limit 100 \
      --json databaseId,displayTitle \
      | jq -r --arg build "$WORKFLOW_RUN_ID" \
        '[.[] | select(.displayTitle | endswith("(build " + $build + ")"))][0].databaseId // empty')"
    if [ -n "$run_id" ]; then
      break
    fi
    sleep 5
  done
  if [ -z "$run_id" ]; then
    echo "No production run found for build $WORKFLOW_RUN_ID ($WORKFLOW_RUN_SHA). Check AUTOMATIC_DEPLOY and RUNNER_ONLINE; both must be true." >&2
    return 1
  fi
  gh run watch "$run_id" --repo "$GITHUB_REPOSITORY" --exit-status || return 1
  [ "$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json conclusion --jq .conclusion)" = "success" ] \
    || { echo "Production run $run_id did not succeed." >&2; return 1; }
}
