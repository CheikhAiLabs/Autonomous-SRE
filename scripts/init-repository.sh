#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

command -v git >/dev/null 2>&1 || { echo "Missing required tool: git" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Missing required tool: gh" >&2; exit 1; }

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || git -C "$ROOT" init -b main

git -C "$ROOT" checkout -B main >/dev/null 2>&1 || true

if ! git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  git -C "$ROOT" add .
  git -C "$ROOT" commit -m "feat: initialize Autonomous-SRE" >/dev/null
fi

if ! gh repo view "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Creating private GitHub repository: $GITHUB_REPOSITORY"
  gh repo create "$GITHUB_REPOSITORY" --private --source="$ROOT" --remote=origin
elif ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$ROOT" remote add origin "https://github.com/${GITHUB_REPOSITORY}.git"
fi

if ! git -C "$ROOT" ls-remote --exit-code origin refs/heads/main >/dev/null 2>&1; then
  git -C "$ROOT" push -u origin main
else
  echo "GitHub main branch already exists; repository initialization will not overwrite it."
fi

echo "Repository ready: https://github.com/$GITHUB_REPOSITORY"
