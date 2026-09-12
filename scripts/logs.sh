#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
kubectl logs -n sre-system -l app.kubernetes.io/name=autonomous-sre-worker -f --tail=100
