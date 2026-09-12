#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$ROOT/config/project.env"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
kubectl -n sre-system rollout status deployment/ollama --timeout=8m
if ! kubectl -n sre-system exec deployment/ollama -- ollama list | grep -Fq "$OLLAMA_MODEL"; then
  echo "Pulling local model: $OLLAMA_MODEL"
  kubectl -n sre-system exec deployment/ollama -- ollama pull "$OLLAMA_MODEL"
fi
