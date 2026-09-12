#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/tool-versions.env"

sudo apt-get update -y
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
  ca-certificates curl git jq rsync unzip openssh-client gettext-base python3 python3-venv tar gzip

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) BIN_ARCH=amd64; AWS_ARCH=x86_64 ;;
  aarch64|arm64) BIN_ARCH=arm64; AWS_ARCH=aarch64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

install_url() {
  local url="$1" dest="$2"
  curl -fsSL "$url" -o /tmp/tool-download
  sudo install -m 0755 /tmp/tool-download "$dest"
  rm -f /tmp/tool-download
}

if ! command -v scw >/dev/null 2>&1 || ! scw version 2>/dev/null | grep -q "$SCALEWAY_CLI_VERSION"; then
  install_url \
    "https://github.com/scaleway/scaleway-cli/releases/download/v${SCALEWAY_CLI_VERSION}/scaleway-cli_${SCALEWAY_CLI_VERSION}_linux_${BIN_ARCH}" \
    /usr/local/bin/scw
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "Installing AWS CLI v2 for Scaleway S3-compatible operations..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
  rm -rf /tmp/aws
  unzip -q /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

if ! command -v kubectl >/dev/null 2>&1 || ! kubectl version --client 2>/dev/null | grep -q "v${KUBECTL_VERSION}"; then
  install_url \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${BIN_ARCH}/kubectl" \
    /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1 || ! helm version --short 2>/dev/null | grep -q "v${HELM_VERSION}"; then
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${BIN_ARCH}.tar.gz" -o /tmp/helm.tgz
  tar -xzf /tmp/helm.tgz -C /tmp
  sudo install -m 0755 "/tmp/linux-${BIN_ARCH}/helm" /usr/local/bin/helm
  rm -rf /tmp/helm.tgz "/tmp/linux-${BIN_ARCH}"
fi

if ! command -v helmfile >/dev/null 2>&1 || ! helmfile --version 2>/dev/null | grep -q "${HELMFILE_VERSION}"; then
  curl -fsSL \
    "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${BIN_ARCH}.tar.gz" \
    -o /tmp/helmfile.tgz
  tar -xzf /tmp/helmfile.tgz -C /tmp helmfile
  sudo install -m 0755 /tmp/helmfile /usr/local/bin/helmfile
  rm -f /tmp/helmfile /tmp/helmfile.tgz
fi

VENV="$ROOT/.deploy-venv"
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --disable-pip-version-check --upgrade pip >/dev/null
"$VENV/bin/python" -m pip install --disable-pip-version-check "ansible-core==${ANSIBLE_CORE_VERSION}" >/dev/null

echo "Deployment tools ready"
scw version | head -n1
aws --version
kubectl version --client
helm version --short
helmfile --version
"$VENV/bin/ansible-playbook" --version | head -n1
