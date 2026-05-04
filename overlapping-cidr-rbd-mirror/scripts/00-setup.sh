#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

MINIKUBE_INSTALL_URL_BASE="https://storage.googleapis.com/minikube/releases"
KUBECTL_RELEASE_BASE="https://dl.k8s.io/release"

install_os_packages() {
  local packages=(curl sed coreutils iproute2 iptables socat qemu-kvm libvirt-daemon-system libvirt-clients)
  local missing=()
  local package

  if command -v apt-get >/dev/null 2>&1; then
    for package in "${packages[@]}"; do
      if ! dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "install ok installed"; then
        missing+=("${package}")
      fi
    done

    if (( ${#missing[@]} == 0 )); then
      log "required OS packages already installed: ${packages[*]}"
      return
    fi

    log "install missing OS packages: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    return
  fi

  log "apt-get not found; verify required OS packages manually: ${packages[*]}"
}

install_os_packages

required_commands=(curl sed base64 socat ip)
for cmd in "${required_commands[@]}"; do
  require_cmd "${cmd}" || {
    echo "required command not found: ${cmd}" >&2
    echo "install ${cmd} first and rerun make setup" >&2
    exit 1
  }
done

if [[ "${MINIKUBE_DRIVER}" == "kvm2" ]]; then
  require_kvm_access
fi

install_dir="${HOME}/.local/bin"
mkdir -p "${install_dir}"
current_path="${PATH}"
export PATH="${install_dir}:${current_path}"

if [[ ":${current_path}:" != *":${install_dir}:"* ]]; then
  log "note: ${install_dir} is not on PATH. setup will place binaries there anyway."
  log "you may need to add it: export PATH=\"${install_dir}:\$PATH\""
fi

current_version() {
  local cmd="$1"
  local parser="$2"
  local output

  if ! output="$(bash -lc "${cmd}" 2>/dev/null)"; then
    echo ""
    return
  fi

  echo "${output}" | awk "${parser}" | tail -n1 | tr -d '\r'
}

install_minikube() {
  local expected="$1"
  local arch
  local os
  local binary
  local tmp
  local tmp_file

  arch="$(uname -m)"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture for minikube: ${arch}" >&2; exit 1 ;;
  esac

  if [[ "${os}" != "linux" ]]; then
    echo "unsupported OS for minikube binary install: ${os}" >&2
    echo "install minikube ${expected} manually and rerun setup" >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  tmp_file="${tmp}/minikube"
  binary="${os}-${arch}"

  log "installing minikube ${expected} to ${install_dir}"
  curl -fsSL -o "${tmp_file}" \
    "${MINIKUBE_INSTALL_URL_BASE}/${expected}/minikube-${binary}"
  chmod +x "${tmp_file}"
  install -m 0755 "${tmp_file}" "${install_dir}/minikube"
}

resolve_kubectl_version() {
  local requested="$1"
  local resolved

  if [[ "${requested}" == "latest" ]]; then
    resolved="$(curl -fsSL "${KUBECTL_RELEASE_BASE}/stable.txt")"
    resolved="${resolved//$'\n'/}"
  else
    resolved="${requested}"
  fi

  if [[ "${resolved}" != v* ]]; then
    resolved="v${resolved}"
  fi

  echo "${resolved}"
}

install_kubectl() {
  local expected="$1"
  local arch
  local os
  local tmp
  local tmp_file

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture for kubectl: ${arch}" >&2; exit 1 ;;
  esac

  tmp="$(mktemp -d)"
  tmp_file="${tmp}/kubectl"

  log "installing kubectl ${expected} to ${install_dir}"
  curl -fsSL -o "${tmp_file}" "${KUBECTL_RELEASE_BASE}/${expected}/bin/${os}/${arch}/kubectl"
  chmod +x "${tmp_file}"
  install -m 0755 "${tmp_file}" "${install_dir}/kubectl"
}

install_subctl() {
  local expected="$1"
  local version="${expected}"

  if [[ "${version}" != "latest" && "${version}" != "devel" && "${version}" != "rc" ]]; then
    version="${version#v}"
  fi

  log "installing subctl ${expected} to ${install_dir}"
  curl -Ls https://get.submariner.io | VERSION="${version}" DESTDIR="${install_dir}" bash
}

ensure_minikube() {
  local expected="${MINIKUBE_VERSION}"
  local installed

  if command -v minikube >/dev/null 2>&1; then
    installed="$(current_version "minikube version --short" 'match($0, /(v?[0-9]+\.[0-9]+\.[0-9]+[^ ]*)/, a) {print a[1]}' )"
  else
    installed=""
  fi

  installed="${installed#v}"
  expected="${expected#v}"

  if [[ "${installed}" != "${expected}" ]]; then
    if [[ -n "${installed}" ]]; then
      log "minikube version mismatch: installed ${installed} (expected ${expected})"
    fi
    install_minikube "v${expected}"
  fi
}

ensure_kubectl() {
  local expected="${KUBECTL_VERSION:-${KUBERNETES_VERSION}}"
  local resolved_version
  local installed
  local installed_clean
  local expected_clean

  resolved_version="$(resolve_kubectl_version "${expected}")"
  if [[ -z "${resolved_version}" ]]; then
    echo "failed to resolve kubectl version from ${expected}" >&2
    exit 1
  fi

  if command -v kubectl >/dev/null 2>&1 && [[ "${expected}" == "latest" ]]; then
    return 0
  fi

  if command -v kubectl >/dev/null 2>&1; then
    installed="$(current_version "kubectl version --client -o json" 'match($0, /"gitVersion"[[:space:]]*:[[:space:]]*"([v]?[0-9]+\.[0-9]+\.[0-9]+([.-][^"]*)?)"/, a) {print a[1]; exit}' )"
  else
    installed=""
  fi

  installed_clean="${installed#v}"
  expected_clean="${resolved_version#v}"

  if [[ "${installed_clean}" != "${expected_clean}" ]]; then
    if [[ -n "${installed}" ]]; then
      log "kubectl version mismatch: installed ${installed} (expected ${resolved_version})"
    fi
    install_kubectl "${resolved_version}"
  fi
}

ensure_subctl() {
  local expected="${SUBCTL_VERSION:-latest}"
  local installed=""

  if command -v subctl >/dev/null 2>&1; then
    installed="$(current_version "subctl version --client" 'match($0, /v?[0-9]+\.[0-9]+\.[0-9]+([.-][^ ]*)?/, a) {print a[0]}' )"
  fi

  if [[ -z "${installed}" || "${expected}" == "latest" ]]; then
    if [[ "${expected}" != "latest" && "${installed#v}" == "${expected#v}" ]]; then
      return 0
    fi
    if [[ "${expected}" == "latest" ]] && [[ -n "${installed}" ]]; then
      return 0
    fi
    install_subctl "${expected}"
    return 0
  fi

  if [[ "${installed#v}" != "${expected#v}" ]]; then
    install_subctl "${expected}"
  fi
}

ensure_minikube
ensure_kubectl
ensure_subctl
