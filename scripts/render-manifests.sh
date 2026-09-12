#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
load_scw_credentials
"$ROOT/scripts/bootstrap-state.sh" >/dev/null
export KUBECONFIG="${KUBECONFIG:-$GENERATED/kubeconfig}"

tofu -chdir="$ROOT/infrastructure/opentofu-platform" init -input=false -backend-config="$GENERATED/platform-backend.hcl" >/dev/null
PLATFORM_FQDN="$(tofu -chdir="$ROOT/infrastructure/opentofu-platform" output -raw control_plane_fqdn)"
export PLATFORM_FQDN

REPO_LOWER="$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
export IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/$REPO_LOWER}"
export IMAGE_TAG="${IMAGE_TAG:-latest}"
export POSTGRES_PASSWORD SMTP_PASSWORD APPROVAL_SIGNING_KEY ALERT_EMAIL SMTP_SMARTHOST SMTP_USERNAME LETSENCRYPT_EMAIL AUTO_REMEDIATION_MODE OLLAMA_MODEL

OUT="$GENERATED/manifests"
rm -rf "$OUT"
mkdir -p "$OUT"

# Static manifests.
for f in "$ROOT"/platform/manifests/*.yaml; do
  cp "$f" "$OUT/$(basename "$f")"
done

kubectl create namespace sre-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# OPA policy ConfigMap generated from the exact Rego source.
kubectl create configmap opa-policy \
  --namespace sre-system \
  --from-file=remediation.rego="$ROOT/platform/policies/remediation.rego" \
  --dry-run=client -o yaml > "$OUT/05-opa-policy.yaml"

# Private GHCR images require a durable read:packages token.
# The per-workflow github.token expires and must never be persisted in Kubernetes.
if [ -z "${GHCR_PULL_TOKEN:-}" ]; then
  echo "GHCR_PULL_TOKEN is required for durable private image pulls." >&2
  exit 1
fi

  kubectl create secret docker-registry ghcr-pull \
    --namespace sre-system \
    --docker-server=ghcr.io \
    --docker-username="${GITHUB_ACTOR:-github-actions}" \
    --docker-password="$GHCR_PULL_TOKEN" \
    --dry-run=client -o yaml > "$OUT/06-ghcr-pull-sre.yaml"
  kubectl create secret docker-registry ghcr-pull \
    --namespace demo \
    --docker-server=ghcr.io \
    --docker-username="${GITHUB_ACTOR:-github-actions}" \
    --docker-password="$GHCR_PULL_TOKEN" \
    --dry-run=client -o yaml > "$OUT/07-ghcr-pull-demo.yaml"
for tpl in "$ROOT"/platform/manifests/*.yaml.tpl; do
  base="$(basename "$tpl" .tpl)"
  envsubst < "$tpl" > "$OUT/$base"
done

# Do not copy templates themselves.
rm -f "$OUT"/*.tpl

echo "$PLATFORM_FQDN" > "$GENERATED/platform-fqdn"
echo "Rendered manifests for https://$PLATFORM_FQDN"
