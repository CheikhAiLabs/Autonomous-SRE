#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
CP_PUBLIC="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_public_ip)"
CP_PRIVATE="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_private_ip)"
mapfile -t WORKER_PUBLIC < <(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -json worker_public_ips | jq -r '.[]')
mapfile -t WORKER_PRIVATE < <(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -json worker_private_ips | jq -r '.[]')

KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/autonomous-sre-github-actions}"
cat >"$GENERATED/inventory.ini" <<EOF
[control_plane]
cp01 ansible_host=$CP_PUBLIC private_ip=$CP_PRIVATE

[workers]
EOF
for i in "${!WORKER_PUBLIC[@]}"; do
  printf 'worker%02d ansible_host=%s private_ip=%s\n' "$((i+1))" "${WORKER_PUBLIC[$i]}" "${WORKER_PRIVATE[$i]}" >>"$GENERATED/inventory.ini"
done
cat >>"$GENERATED/inventory.ini" <<EOF

[k3s_cluster:children]
control_plane
workers

[k3s_cluster:vars]
ansible_user=root
ansible_ssh_private_key_file=$KEY
k3s_version=v1.36.4+k3s1
EOF

echo "Inventory rendered: $GENERATED/inventory.ini"
