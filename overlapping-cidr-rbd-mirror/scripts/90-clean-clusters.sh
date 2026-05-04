#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd minikube
require_common_tools

remove_kubeconfig_entries() {
  local profile="$1"
  local kubeconfig
  local current
  local context_name

  if [[ "${profile}" == "${SOURCE_CLUSTER_PROFILE}" ]]; then
    context_name="${SOURCE_CLUSTER_PROFILE}"
  elif [[ "${profile}" == "${RECOVERY_CLUSTER_PROFILE}" ]]; then
    context_name="${RECOVERY_CLUSTER_PROFILE}"
  else
    context_name="${profile}"
  fi

  kubeconfig="$(kubeconfig_file)"

  kubectl --kubeconfig="${kubeconfig}" config delete-context "${context_name}" >/dev/null 2>&1 || true
  kubectl --kubeconfig="${kubeconfig}" config delete-user "${context_name}" >/dev/null 2>&1 || true
  kubectl --kubeconfig="${kubeconfig}" config delete-cluster "${context_name}" >/dev/null 2>&1 || true

  # kubectl currently keeps `current-context` even when no contexts remain, so unset
  # it if it still points to the deleted context.
  current="$(kubectl --kubeconfig="${kubeconfig}" config view -o jsonpath='{.current-context}' 2>/dev/null || true)"
  if [[ -n "${current}" && "${current}" == "${context_name}" ]]; then
    kubectl --kubeconfig="${kubeconfig}" config unset current-context >/dev/null 2>&1 || true
  fi
}

remove_minikube_state() {
  local profile="$1"
  local profile_dir="${MINIKUBE_HOME}/.minikube/profiles/${profile}"
  local machine_dir="${MINIKUBE_HOME}/.minikube/machines/${profile}"

  log "remove minikube state for ${profile}"
  log "profile dir: ${profile_dir}"
  log "machine dir: ${machine_dir}"
  rm -rf "${profile_dir}" "${machine_dir}"

  if [[ -e "${profile_dir}" || -e "${machine_dir}" ]]; then
    echo "failed to remove minikube state for ${profile}" >&2
    echo "profile dir: ${profile_dir}" >&2
    echo "machine dir: ${machine_dir}" >&2
    echo "remaining files:" >&2
    find "${profile_dir}" "${machine_dir}" -maxdepth 2 -print 2>/dev/null | sort >&2 || true
    return 1
  fi

  log "removed minikube state for ${profile}"
}

remove_libvirt_domain() {
  local profile="$1"
  local network="mk-${profile}"
  local net_uuid
  local volume

  if ! command -v virsh >/dev/null 2>&1; then
    log "virsh not found; skip libvirt cleanup for ${profile}"
    return 0
  fi

  log "remove libvirt domain ${profile} if present"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" destroy "${profile}" >/dev/null 2>&1 || true
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" undefine "${profile}" --remove-all-storage >/dev/null 2>&1 || true
  if virsh --connect "${MINIKUBE_KVM_QEMU_URI}" dominfo "${profile}" >/dev/null 2>&1; then
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" undefine "${profile}" --nvram --managed-save --snapshots-metadata >/dev/null 2>&1 || true
  fi

  if virsh --connect "${MINIKUBE_KVM_QEMU_URI}" pool-info default >/dev/null 2>&1; then
    while read -r volume; do
      [[ -z "${volume}" ]] && continue
      log "remove libvirt storage volume ${volume}"
      virsh --connect "${MINIKUBE_KVM_QEMU_URI}" vol-delete --pool default "${volume}" >/dev/null 2>&1 || true
    done < <(virsh --connect "${MINIKUBE_KVM_QEMU_URI}" vol-list default 2>/dev/null | awk -v profile="${profile}" '$1 ~ profile {print $1}')
  fi

  log "remove libvirt network ${network} if present"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-destroy "${network}" || true
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-undefine "${network}" || true

  net_uuid="$(virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" 2>/dev/null | awk '/UUID:/ {print $2; exit}' || true)"
  if [[ -n "${net_uuid}" ]]; then
    echo "libvirt network still exists after cleanup: ${network} uuid=${net_uuid}" >&2
    echo "current libvirt networks:" >&2
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-list --all >&2 || true
    return 1
  fi
}

cleanup_profile() {
  local profile="$1"

  log "stop and delete minikube profile ${profile} (idempotent)"
  remove_libvirt_domain "${profile}"
  minikube stop -p "${profile}" >/dev/null 2>&1 || true
  minikube delete -p "${profile}" >/dev/null 2>&1 || true
  remove_libvirt_domain "${profile}"
  remove_minikube_state "${profile}"
  remove_kubeconfig_entries "${profile}"
}

remove_legacy_shared_network() {
  local network="overlap-cidr"

  if ! command -v virsh >/dev/null 2>&1; then
    return 0
  fi

  if virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" >/dev/null 2>&1; then
    log "remove legacy shared libvirt network ${network} if present"
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-destroy "${network}" >/dev/null 2>&1 || true
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-undefine "${network}" >/dev/null 2>&1 || true
  fi
}

log "cleanup minikube profiles"
cleanup_profile "${SOURCE_CLUSTER_PROFILE}"
cleanup_profile "${RECOVERY_CLUSTER_PROFILE}"
remove_legacy_shared_network

if [[ -n "${CLEAN_EXTRA_MINIKUBE_PROFILES:-}" ]]; then
  for extra_profile in ${CLEAN_EXTRA_MINIKUBE_PROFILES}; do
    case "${extra_profile}" in
      "${SOURCE_CLUSTER_PROFILE}"|"${RECOVERY_CLUSTER_PROFILE}") continue ;;
    esac
    cleanup_profile "${extra_profile}"
  done
fi

if [[ -f "${BROKER_INFO_FILE}" ]]; then
  log "remove broker info file ${BROKER_INFO_FILE}"
  rm -f "${BROKER_INFO_FILE}"
fi

log "cleanup done"
