#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd update-alternatives
require_cmd virsh
require_kvm_access

libvirt_qemu_conf_value() {
  local key="$1"
  local conf="/etc/libvirt/qemu.conf"

  [[ -f "${conf}" ]] || return 0
  awk -F\" -v key="${key}" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {print $2; exit}' "${conf}"
}

detect_libvirt_qemu_user() {
  local configured
  configured="$(libvirt_qemu_conf_value user)"
  if [[ -n "${configured}" ]]; then
    echo "${configured}"
    return 0
  fi

  for candidate in libvirt-qemu qemu; do
    if id -u "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done

  echo "root"
}

set_qemu_conf_value() {
  local key="$1"
  local value="$2"
  local conf="/etc/libvirt/qemu.conf"
  local tmp

  [[ -f "${conf}" ]] || return 0
  [[ -w "${conf}" ]] || {
    log "qemu.conf is not writable, skip setting ${key}"
    return 0
  }

  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${conf}"; then
    tmp="$(mktemp)"
    sed -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${value}\"|" "${conf}" >"${tmp}"
    install -m 0644 "${tmp}" "${conf}"
    rm -f "${tmp}"
  else
    printf '\n%s = "%s"\n' "${key}" "${value}" >>"${conf}"
  fi
}

probe_qemu_as_user() {
  local user="$1"
  local err_file
  local rc=0

  command -v qemu-system-x86_64 >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0

  err_file="$(mktemp)"
  if [[ "${user}" == "root" ]]; then
    timeout 3 qemu-system-x86_64 -machine none -accel kvm -display none -nodefaults -no-user-config -monitor none -serial none -S >/dev/null 2>"${err_file}" || rc=$?
  elif command -v runuser >/dev/null 2>&1; then
    timeout 3 runuser -u "${user}" -- qemu-system-x86_64 -machine none -accel kvm -display none -nodefaults -no-user-config -monitor none -serial none -S >/dev/null 2>"${err_file}" || rc=$?
  else
    rm -f "${err_file}"
    return 0
  fi

  if [[ "${rc}" -eq 0 || "${rc}" -eq 124 ]]; then
    log "qemu KVM probe succeeded as ${user}"
    rm -f "${err_file}"
    return 0
  fi

  echo "qemu KVM probe failed as ${user}; libvirt/minikube kvm2 is likely to fail." >&2
  sed -n '1,80p' "${err_file}" >&2 || true
  rm -f "${err_file}"
  dump_kvm_state
  return 1
}

configure_libvirt_qemu_kvm_access() {
  local qemu_user
  local kvm_gid
  local dev_kvm_gid

  qemu_user="$(detect_libvirt_qemu_user)"
  log "libvirt QEMU user candidate: ${qemu_user}"

  if [[ "${qemu_user}" != "root" && -e /dev/kvm ]] && getent group kvm >/dev/null 2>&1; then
    kvm_gid="$(getent group kvm | awk -F: '{print $3}')"
    dev_kvm_gid="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"

    if [[ -n "${dev_kvm_gid}" && "${dev_kvm_gid}" != "${kvm_gid}" ]]; then
      log "set /dev/kvm group to kvm (was gid ${dev_kvm_gid})"
      chgrp kvm /dev/kvm || true
    fi

    log "set /dev/kvm mode to 0660"
    chmod 0660 /dev/kvm || true

    if id -u "${qemu_user}" >/dev/null 2>&1; then
      log "ensure ${qemu_user} is in kvm group"
      usermod -aG kvm "${qemu_user}" || true
    fi
  fi

  if [[ -f /etc/libvirt/qemu.conf ]]; then
    log "ensure libvirt qemu.conf uses group kvm"
    set_qemu_conf_value group kvm
  fi
}

set_alternative_if_present() {
  local name="$1"
  local path="$2"

  if [[ -x "${path}" ]]; then
    log "set ${name} alternative to ${path}"
    if ! update-alternatives --set "${name}" "${path}"; then
      log "failed to set ${name} alternative; continue with current host setting"
    fi
  else
    log "alternative target not found, skip ${name}: ${path}"
  fi
}

print_wsl_dhcp_hint() {
  if ! grep -qi 'microsoft.*wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    return 0
  fi

  cat >&2 <<'EOF'

WSL detected. If no Linux DHCP listener is shown but libvirt dnsmasq still says:
  dnsmasq: failed to bind DHCP server socket: Address already in use

then WSL mirrored networking may be blocking Linux from binding DHCP ports used
on the Windows side. Add this to the Windows user's .wslconfig, then run
`wsl --shutdown` from Windows and reopen this distro:

[wsl2]
networkingMode=mirrored

[experimental]
ignoredPorts=53,67,68,547

EOF
}

libvirt_network_gateway() {
  local network="$1"

  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-dumpxml "${network}" 2>/dev/null \
    | sed -n "s/.*<ip address=['\"]\\([^'\"]*\\)['\"].*/\\1/p" \
    | head -n1
}

prepare_profile_libvirt_network() {
  local profile="$1"
  local cidr_var="$2"
  local network="mk-${profile}"
  local gateway
  local cidr

  gateway="$(libvirt_network_gateway "${network}" || true)"
  if [[ -z "${gateway}" ]]; then
    log "skip profile libvirt network repair for ${profile}: ${network} not found"
    printf -v "${cidr_var}" '%s' ""
    return 0
  fi

  cidr="${gateway%.*}.0/24"
  repair_libvirt_network_dhcp_gateway "${network}" "${gateway}"
  ensure_libvirt_network_bridge_up "${network}"
  ensure_libvirt_network_dhcp_listener "${network}"
  ensure_host_nat_for_cidr "${cidr}" "${profile}"
  printf -v "${cidr_var}" '%s' "${cidr}"
}

log "switch iptables alternatives to legacy for libvirt network startup"
set_alternative_if_present iptables /usr/sbin/iptables-legacy
set_alternative_if_present ip6tables /usr/sbin/ip6tables-legacy
set_alternative_if_present arptables /usr/sbin/arptables-legacy
set_alternative_if_present ebtables /usr/sbin/ebtables-legacy

configure_libvirt_qemu_kvm_access

if command -v systemctl >/dev/null 2>&1; then
  log "restart libvirt service if available"
  systemctl restart libvirtd >/dev/null 2>&1 || systemctl restart libvirt-daemon >/dev/null 2>&1 || true
fi

probe_qemu_as_user "$(detect_libvirt_qemu_user)"

if command -v ss >/dev/null 2>&1; then
  log "current libvirt DHCP listeners"
  log_command_text "ss -lunp | grep -E ':(67|547)\\b'"
  ss -lunp | grep -E ':(67|547)\b' || true
fi

log "libvirt network/interface diagnostics before minikube start"
run_logged virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-list --all || true
run_logged ip -br addr || true
run_logged ip route || true

source_profile_cidr=""
recovery_profile_cidr=""
prepare_profile_libvirt_network "${SOURCE_CLUSTER_PROFILE}" source_profile_cidr
prepare_profile_libvirt_network "${RECOVERY_CLUSTER_PROFILE}" recovery_profile_cidr
if [[ -n "${source_profile_cidr}" && -n "${recovery_profile_cidr}" && "${source_profile_cidr}" != "${recovery_profile_cidr}" ]]; then
  ensure_host_forward_between_cidrs "${source_profile_cidr}" "${recovery_profile_cidr}"
fi

run_logged virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-list --all
