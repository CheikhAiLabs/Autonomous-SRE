#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.generated/kubeconfig}"
kubectl get nodes -o wide
kubectl get pods -A
kubectl get gateway,httproute -A 2>/dev/null || true
