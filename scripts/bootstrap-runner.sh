#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
require_repo
"$ROOT/scripts/bootstrap-state.sh"

KEY="$HOME/.ssh/autonomous-sre-github-actions"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N '' -C 'autonomous-sre-github-actions' -f "$KEY" >/dev/null
fi

if ! scw iam ssh-key list name=autonomous-sre-github-actions project-id="$SCW_PROJECT_ID" -o json | jq -e 'length > 0' >/dev/null; then
  scw iam ssh-key create \
    name=autonomous-sre-github-actions \
    public-key="$(cat "$KEY.pub")" \
    project-id="$SCW_PROJECT_ID" >/dev/null
fi

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_operator_cidr="$OPERATOR_CIDR"
export TF_VAR_runner_type="$RUNNER_TYPE"

tofu -chdir="$ROOT/infrastructure/opentofu-runner" init -input=false -backend-config="$GENERATED/runner-backend.hcl" >/dev/null
tofu -chdir="$ROOT/infrastructure/opentofu-runner" apply -input=false -auto-approve

RUNNER_IP="$(tofu -chdir="$ROOT/infrastructure/opentofu-runner" output -raw runner_ip)"
RUNNER_CIDR="${RUNNER_IP}/32"

echo "Waiting for runner SSH: $RUNNER_IP"
for attempt in $(seq 1 60); do
  wait_progress "Waiting for runner SSH" "$attempt" 60
  if ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$RUNNER_IP" true 2>/dev/null; then
    [ -t 1 ] && printf '\n' || true
    break
  fi
  sleep 5
done
ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$RUNNER_IP" true

REG_TOKEN="$(gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runners/registration-token" --jq .token)"
RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"

ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$RUNNER_IP" \
  "REPO='$GITHUB_REPOSITORY' REG_TOKEN='$REG_TOKEN' RUNNER_VERSION='$RUNNER_VERSION' bash -s" <<'REMOTE'
set -Eeuo pipefail
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq unzip rsync openssh-client gettext-base python3 python3-venv make gnupg lsb-release
if ! command -v scw >/dev/null 2>&1; then
  curl -fsSL "https://github.com/scaleway/scaleway-cli/releases/download/v2.60.0/scaleway-cli_2.60.0_linux_amd64" -o /usr/local/bin/scw
  chmod 0755 /usr/local/bin/scw
fi
id actions >/dev/null 2>&1 || useradd --create-home --shell /bin/bash actions
echo 'actions ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/actions
chmod 440 /etc/sudoers.d/actions
mkdir -p /opt/actions-runner
chown actions:actions /opt/actions-runner
cd /opt/actions-runner
if [ ! -x ./run.sh ]; then
  curl -fsSLo actions-runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner.tar.gz
  rm actions-runner.tar.gz
  chown -R actions:actions /opt/actions-runner
fi
if [ ! -f .runner ]; then
  sudo -u actions ./config.sh \
    --url "https://github.com/$REPO" \
    --token "$REG_TOKEN" \
    --name autonomous-sre-scaleway-01 \
    --labels autonomous-sre,linux,x64 \
    --work _work \
    --unattended \
    --replace
fi
SERVICE_FILE="$(find /etc/systemd/system -maxdepth 1 -type f -name 'actions.runner.*.autonomous-sre-scaleway-01.service' -print -quit)"
if [ -z "$SERVICE_FILE" ]; then
  echo "Installing GitHub Actions runner systemd service..."
  ./svc.sh install actions
else
  echo "GitHub Actions runner service already installed."
  echo "Reusing: $SERVICE_FILE"
fi
./svc.sh start
REMOTE

echo "Waiting for GitHub runner to report online..."
STATUS=""
for attempt in $(seq 1 30); do
  wait_progress "Waiting for GitHub runner" "$attempt" 30
  STATUS="$(gh api "repos/$GITHUB_REPOSITORY/actions/runners" --jq '.runners[] | select(.name=="autonomous-sre-scaleway-01") | .status' 2>/dev/null || true)"
  if [ "$STATUS" = "online" ]; then
    [ -t 1 ] && printf '\n' || true
    break
  fi
  sleep 5
done
[ "$STATUS" = "online" ] || { echo "Runner did not become online in time" >&2; exit 1; }

# Create/update GitHub production environment and secrets/variables.
gh api -X PUT "repos/$GITHUB_REPOSITORY/environments/production" >/dev/null

gh secret set SCW_ACCESS_KEY --repo "$GITHUB_REPOSITORY" --env production --body "$SCW_ACCESS_KEY"
gh secret set SCW_SECRET_KEY --repo "$GITHUB_REPOSITORY" --env production --body "$SCW_SECRET_KEY"
gh secret set SCW_PROJECT_ID --repo "$GITHUB_REPOSITORY" --env production --body "$SCW_PROJECT_ID"
gh secret set DEPLOY_SSH_PRIVATE_KEY --repo "$GITHUB_REPOSITORY" --env production < "$KEY"
gh secret set APPROVAL_SIGNING_KEY --repo "$GITHUB_REPOSITORY" --env production --body "$APPROVAL_SIGNING_KEY"
gh secret set POSTGRES_PASSWORD --repo "$GITHUB_REPOSITORY" --env production --body "$POSTGRES_PASSWORD"
if [ -n "${SMTP_PASSWORD:-}" ]; then
  gh secret set SMTP_PASSWORD --repo "$GITHUB_REPOSITORY" --env production --body "$SMTP_PASSWORD"
fi
if [ -n "${GHCR_PULL_TOKEN:-}" ]; then
  gh secret set GHCR_PULL_TOKEN --repo "$GITHUB_REPOSITORY" --env production --body "$GHCR_PULL_TOKEN"
fi

gh variable set OPERATOR_CIDR --repo "$GITHUB_REPOSITORY" --env production --body "$OPERATOR_CIDR"
gh variable set RUNNER_CIDR --repo "$GITHUB_REPOSITORY" --env production --body "$RUNNER_CIDR"
gh variable set ALERT_EMAIL --repo "$GITHUB_REPOSITORY" --env production --body "$ALERT_EMAIL"
gh variable set SCW_REGION --repo "$GITHUB_REPOSITORY" --env production --body "$SCW_REGION"
gh variable set SCW_ZONE --repo "$GITHUB_REPOSITORY" --env production --body "$SCW_ZONE"
gh variable set CONTROL_PLANE_TYPE --repo "$GITHUB_REPOSITORY" --env production --body "$CONTROL_PLANE_TYPE"
gh variable set WORKER_TYPE --repo "$GITHUB_REPOSITORY" --env production --body "$WORKER_TYPE"
gh variable set WORKER_COUNT --repo "$GITHUB_REPOSITORY" --env production --body "$WORKER_COUNT"
gh variable set AUTO_REMEDIATION_MODE --repo "$GITHUB_REPOSITORY" --env production --body "$AUTO_REMEDIATION_MODE"
gh variable set OLLAMA_MODEL --repo "$GITHUB_REPOSITORY" --env production --body "$OLLAMA_MODEL"
gh variable set SMTP_SMARTHOST --repo "$GITHUB_REPOSITORY" --env production --body "$SMTP_SMARTHOST"
gh variable set SMTP_USERNAME --repo "$GITHUB_REPOSITORY" --env production --body "$SMTP_USERNAME"
gh variable set LETSENCRYPT_EMAIL --repo "$GITHUB_REPOSITORY" --env production --body "$LETSENCRYPT_EMAIL"
gh variable set AUTOMATIC_DEPLOY --repo "$GITHUB_REPOSITORY" --body "true"

echo "Runner online target: autonomous-sre-scaleway-01 ($RUNNER_IP)"
