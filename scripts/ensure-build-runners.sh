#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials

: "${RUNNER_ADMIN_TOKEN:?RUNNER_ADMIN_TOKEN is required}"
: "${DEPLOY_SSH_PRIVATE_KEY:?DEPLOY_SSH_PRIVATE_KEY is required}"
: "${RUNNER_CIDR:?RUNNER_CIDR is required}"

BUILD_RUNNER_COUNT="${BUILD_RUNNER_COUNT:-3}"
BUILD_RUNNER_TYPE="${BUILD_RUNNER_TYPE:-DEV1-M}"
POOL_DIR="$HOME/.autonomous-sre"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

mkdir -p "$POOL_DIR"
printf 'active %s\n' "$(date +%s)" > "$POOL_DIR/build-pool.state"

api() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $RUNNER_ADMIN_TOKEN" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "https://api.github.com/$1"
}

online_count() {
  api "repos/$GITHUB_REPOSITORY/actions/runners?per_page=100" \
    | jq '[.runners[] | select(.status == "online") | select(any(.labels[]?; .name == "autonomous-sre-build"))] | length'
}

if [ "$(online_count)" -ge "$BUILD_RUNNER_COUNT" ]; then
  echo "Build runner pool already online; reusing it."
  exit 0
fi

"$ROOT/scripts/bootstrap-state.sh" >/dev/null

export TF_VAR_project_id="$SCW_PROJECT_ID"
export TF_VAR_region="$SCW_REGION"
export TF_VAR_zone="$SCW_ZONE"
export TF_VAR_manager_cidr="$RUNNER_CIDR"
export TF_VAR_runner_type="$BUILD_RUNNER_TYPE"
export TF_VAR_runner_count="$BUILD_RUNNER_COUNT"

tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" init \
  -input=false \
  -backend-config="$GENERATED/build-runners-backend.hcl" >/dev/null

tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" apply -input=false -auto-approve

mapfile -t RUNNER_IPS < <(tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" output -json runner_ips | jq -r '.[]')
mapfile -t RUNNER_NAMES < <(tofu -chdir="$ROOT/infrastructure/opentofu-build-runners" output -json runner_names | jq -r '.[]')

KEY="$RUNNER_TEMP/autonomous-sre-build-runner-key"
printf '%s\n' "$DEPLOY_SSH_PRIVATE_KEY" > "$KEY"
chmod 0600 "$KEY"

REG_TOKEN="$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $RUNNER_ADMIN_TOKEN" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runners/registration-token" \
  | jq -r '.token')"
RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')"

for i in "${!RUNNER_IPS[@]}"; do
  ip="${RUNNER_IPS[$i]}"
  name="${RUNNER_NAMES[$i]}"
  echo "Preparing $name at $ip..."

  for attempt in $(seq 1 60); do
    if ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$ip" true 2>/dev/null; then
      break
    fi
    [ "$attempt" -lt 60 ] || { echo "SSH timeout for $name ($ip)" >&2; exit 1; }
    sleep 5
  done

  ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$ip" \
    "REPO='$GITHUB_REPOSITORY' REG_TOKEN='$REG_TOKEN' RUNNER_VERSION='$RUNNER_VERSION' RUNNER_NAME='$name' bash -s" <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y ca-certificates curl git jq unzip rsync openssh-client python3 python3-venv make docker.io >/dev/null
systemctl enable --now docker
id actions >/dev/null 2>&1 || useradd --create-home --shell /bin/bash actions
usermod -aG docker actions
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
    --name "$RUNNER_NAME" \
    --labels autonomous-sre-build \
    --work _work \
    --unattended \
    --replace
fi
SERVICE_FILE="$(find /etc/systemd/system -maxdepth 1 -type f -name "actions.runner.*.${RUNNER_NAME}.service" -print -quit)"
if [ -z "$SERVICE_FILE" ]; then
  ./svc.sh install actions
fi
./svc.sh start
REMOTE
done

for attempt in $(seq 1 36); do
  count="$(online_count)"
  if [ "$count" -ge "$BUILD_RUNNER_COUNT" ]; then
    echo "Build runner pool online: $count/$BUILD_RUNNER_COUNT"
    exit 0
  fi
  wait_progress "Waiting for build runner pool" "$attempt" 36
  sleep 5
done

echo "Build runner pool did not become fully online." >&2
exit 1
