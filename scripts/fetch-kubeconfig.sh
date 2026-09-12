#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
CP_PUBLIC="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_public_ip)"
KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/autonomous-sre-github-actions}"
ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no root@"$CP_PUBLIC" 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s/127.0.0.1/$CP_PUBLIC/g" > "$GENERATED/kubeconfig"
chmod 600 "$GENERATED/kubeconfig"
echo "Kubeconfig: $GENERATED/kubeconfig"
