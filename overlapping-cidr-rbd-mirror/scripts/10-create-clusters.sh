#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd minikube
require_cmd timeout
require_common_tools
require_minikube_version "${MINIKUBE_VERSION}"

dump_path_state() {
  local path="$1"

  if [[ -e "${path}" ]]; then
    log "path exists: ${path}"
    ls -ld "${path}" || true
    find "${path}" -maxdepth 2 -mindepth 1 -print | sort | sed 's/^/  /' || true
  else
    log "path absent: ${path}"
  fi
}

dump_minikube_diagnostics() {
  local profile="$1"
  local profile_dir="${MINIKUBE_HOME}/.minikube/profiles/${profile}"
  local machine_dir="${MINIKUBE_HOME}/.minikube/machines/${profile}"
  local last_start="${MINIKUBE_HOME}/.minikube/logs/lastStart.txt"

  log "diagnostics for minikube profile ${profile}"
  log "MINIKUBE_HOME=${MINIKUBE_HOME}"
  dump_path_state "${profile_dir}"
  dump_path_state "${machine_dir}"

  if [[ -f "${profile_dir}/config.json" ]]; then
    log "profile config ${profile_dir}/config.json"
    sed -n '1,220p' "${profile_dir}/config.json" || true
  fi

  if [[ -f "${machine_dir}/config.json" ]]; then
    log "machine config ${machine_dir}/config.json"
    sed -n '1,220p' "${machine_dir}/config.json" || true
  fi

  if [[ -f "${profile_dir}/events.json" ]]; then
    log "profile events tail ${profile_dir}/events.json"
    tail -n 120 "${profile_dir}/events.json" || true
  fi

  if [[ -f "${last_start}" ]]; then
    log "minikube lastStart tail ${last_start}"
    tail -n 240 "${last_start}" || true
  fi

  log "minikube profile list"
  minikube profile list || true
}

use_existing_cluster_if_ready() {
  local profile="$1"
  local profile_dir="${MINIKUBE_HOME}/.minikube/profiles/${profile}"
  local machine_dir="${MINIKUBE_HOME}/.minikube/machines/${profile}"

  if [[ ! -e "${profile_dir}" && ! -e "${machine_dir}" ]]; then
    return 1
  fi

  log "existing minikube state detected for ${profile}; checking whether it is usable"
  if minikube_cmd -p "${profile}" status >/dev/null 2>&1; then
    sync_profile_kubeconfig "${profile}"
    if kubectl --context "${profile}" get nodes >/dev/null 2>&1; then
      ensure_isolated_node_internal_ip "${profile}"
      if ! validate_cluster_driver_and_ip "${profile}"; then
        echo "existing minikube profile ${profile} is not valid for kvm2/libvirt; run 'make clean-clusters'" >&2
        return 2
      fi
      log "reuse existing minikube profile ${profile}"
      kc_logged "${profile}" get nodes -o wide
      return 0
    fi
  fi

  echo "stale or unusable minikube state exists for ${profile}; run 'make clean-clusters' before creating clusters" >&2
  dump_minikube_diagnostics "${profile}" >&2
  return 2
}

cleanup_stale_cluster() {
  local profile="$1"

  log "attempting cleanup for stale minikube state ${profile}"
  minikube stop -p "${profile}" >/dev/null 2>&1 || true
  minikube delete -p "${profile}" >/dev/null 2>&1 || true
  rm -rf "${MINIKUBE_HOME}/.minikube/profiles/${profile}" "${MINIKUBE_HOME}/.minikube/machines/${profile}"
  if command -v virsh >/dev/null 2>&1; then
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" destroy "${profile}" >/dev/null 2>&1 || true
    virsh --connect "${MINIKUBE_KVM_QEMU_URI}" undefine "${profile}" --remove-all-storage >/dev/null 2>&1 || true
  fi
}

start_minikube_cluster() {
  local profile="$1"
  shift
  minikube_cmd start --profile="${profile}" "$@"
}

profile_ssh_key() {
  local profile="$1"
  local machine_config="${MINIKUBE_HOME}/.minikube/machines/${profile}/config.json"

  awk -F: '/"SSHKeyPath"/{gsub(/^[[:space:]]*"SSHKeyPath"[[:space:]]*:[[:space:]]*"|"[,]?[[:space:]]*$/, "", $0); print $0; exit}' "${machine_config}" 2>/dev/null || true
}

profile_ssh() {
  local profile="$1"
  shift
  local private_ip
  local ssh_key

  private_ip="$(profile_private_ip "${profile}")"
  ssh_key="$(profile_ssh_key "${profile}")"
  if [[ -z "${private_ip}" || -z "${ssh_key}" || ! -f "${ssh_key}" ]]; then
    return 1
  fi

  timeout 20s ssh \
    -i "${ssh_key}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    docker@"${private_ip}" "$@"
}

profile_internal_ip() {
  local profile="$1"

  case "${profile}" in
    "${SOURCE_CLUSTER_PROFILE}") printf '%s\n' "${SOURCE_CLUSTER_INTERNAL_IP}" ;;
    "${RECOVERY_CLUSTER_PROFILE}") printf '%s\n' "${RECOVERY_CLUSTER_INTERNAL_IP}" ;;
    *) echo "unknown cluster profile for internal IP: ${profile}" >&2; return 1 ;;
  esac
}

wait_for_node_ready() {
  local profile="$1"
  local timeout="${2:-300s}"

  log "wait for node ${profile} to become Ready"
  if ! kubectl --context "${profile}" wait --for=condition=Ready "node/${profile}" --timeout="${timeout}"; then
    echo "node ${profile} did not become Ready within ${timeout}" >&2
    kc_logged "${profile}" get nodes -o wide >&2 || true
    kc_logged "${profile}" get pods -A >&2 || true
    return 1
  fi
}

wait_for_node_internal_ip() {
  local profile="$1"
  local expected_ip="$2"
  local attempt=1
  local retries="${3:-60}"
  local sleep_seconds="${4:-2}"
  local current_ip

  while (( attempt <= retries )); do
    current_ip="$(kubectl --context "${profile}" get node "${profile}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    if [[ "${current_ip}" == "${expected_ip}" ]]; then
      return 0
    fi

    log "node InternalIP on ${profile} is ${current_ip:-empty}, waiting for ${expected_ip} (${attempt}/${retries})"
    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "timed out waiting for node InternalIP on ${profile}: expected=${expected_ip}" >&2
  kc_logged "${profile}" get node "${profile}" -o wide >&2 || true
  return 1
}

configure_isolated_internal_interface() {
  local profile="$1"
  local node_ip="$2"
  local prefix_len="${CLUSTER_INTERNAL_CIDR#*/}"

  log "configure isolated node InternalIP interface on ${profile}: ${CLUSTER_INTERNAL_IFACE}=${node_ip}/${prefix_len}"
  profile_ssh "${profile}" "sudo sh -s '${CLUSTER_INTERNAL_IFACE}' '${node_ip}' '${prefix_len}'" <<'EOF'
set -eu
iface="$1"
node_ip="$2"
prefix_len="$3"

sudo modprobe dummy 2>/dev/null || true
if ! ip link show "${iface}" >/dev/null 2>&1; then
  sudo ip link add "${iface}" type dummy
fi
sudo ip addr flush dev "${iface}" || true
sudo ip addr add "${node_ip}/${prefix_len}" dev "${iface}"
sudo ip link set "${iface}" up
EOF
}

ensure_kubelet_node_ip() {
  local profile="$1"
  local node_ip="$2"

  log "ensure kubelet node-ip on ${profile}: ${node_ip}"
  profile_ssh "${profile}" "sudo sh -s '${node_ip}'" <<'EOF'
set -eu
node_ip="$1"
flags_file="/var/lib/kubelet/kubeadm-flags.env"
dropin_file="/etc/systemd/system/kubelet.service.d/10-kubeadm.conf"

if [ ! -f "${dropin_file}" ]; then
  echo "missing ${dropin_file}" >&2
  exit 1
fi

sudo sed -i -E "s/(--node-ip=)[^[:space:]]+/\1${node_ip}/" "${dropin_file}"
if ! grep -q -- '--node-ip=' "${dropin_file}"; then
  sudo sed -i -E "/^ExecStart=/ s|$| --node-ip=${node_ip}|" "${dropin_file}"
fi

if [ -f "${flags_file}" ]; then
  . "${flags_file}"
  args="${KUBELET_KUBEADM_ARGS:-}"
  args="$(printf '%s' "${args}" | sed -E 's/(^|[[:space:]])--node-ip=[^[:space:]]+//g' | xargs)"
  printf 'KUBELET_KUBEADM_ARGS="%s --node-ip=%s"\n' "${args}" "${node_ip}" | sudo tee "${flags_file}" >/dev/null
fi

sudo systemctl daemon-reload
sudo systemctl restart kubelet
EOF
}

ensure_isolated_node_internal_ip() {
  local profile="$1"
  local expected_ip
  local current_ip

  expected_ip="$(profile_internal_ip "${profile}")"
  configure_isolated_internal_interface "${profile}" "${expected_ip}"
  current_ip="$(kubectl --context "${profile}" get node "${profile}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

  if [[ "${current_ip}" != "${expected_ip}" ]]; then
    ensure_kubelet_node_ip "${profile}" "${expected_ip}"
    wait_for_node_ready "${profile}"
    wait_for_node_internal_ip "${profile}" "${expected_ip}"
  fi

  log "node InternalIP uses isolated non-shared CIDR on ${profile}: ${expected_ip}"
}

ipv4_to_int() {
  local ip="$1"
  local a b c d

  IFS=. read -r a b c d <<<"${ip}"
  printf '%u\n' "$(((a << 24) + (b << 16) + (c << 8) + d))"
}

ipv4_in_cidr() {
  local ip="$1"
  local cidr="$2"
  local network="${cidr%/*}"
  local prefix="${cidr#*/}"
  local ip_int
  local network_int
  local mask

  [[ "${ip}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  ip_int="$(ipv4_to_int "${ip}")"
  network_int="$(ipv4_to_int "${network}")"
  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))

  (( (ip_int & mask) == (network_int & mask) ))
}

validate_pod_network_cidr() {
  local profile="$1"
  local node_pod_cidr
  local node_ip
  local profile_ip
  local pod_ips
  local pod_ip
  local saw_pod_cidr_ip=0

  node_pod_cidr="$(kubectl --context "${profile}" get node "${profile}" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || true)"
  if [[ "${node_pod_cidr}" != "${POD_CIDR}" ]]; then
    echo "unexpected node podCIDR for ${profile}: ${node_pod_cidr:-empty}" >&2
    echo "expected POD_CIDR: ${POD_CIDR}" >&2
    kc_logged "${profile}" get node "${profile}" -o yaml >&2 || true
    return 1
  fi

  pod_ips="$(kubectl --context "${profile}" get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null || true)"
  node_ip="$(kubectl --context "${profile}" get node "${profile}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  profile_ip="$(profile_private_ip "${profile}")"

  while read -r _namespace _name pod_ip; do
    [[ -n "${pod_ip}" ]] || continue
    if [[ "${pod_ip}" == "${node_ip}" || "${pod_ip}" == "${profile_ip}" ]]; then
      continue
    fi
    if ! ipv4_in_cidr "${pod_ip}" "${POD_CIDR}"; then
      echo "pod IP outside POD_CIDR on ${profile}: ${pod_ip} (expected ${POD_CIDR})" >&2
      echo "${pod_ips}" >&2
      return 1
    fi
    saw_pod_cidr_ip=1
  done <<<"${pod_ips}"

  if (( saw_pod_cidr_ip == 0 )); then
    echo "no non-hostNetwork pod IP found in POD_CIDR on ${profile}: ${POD_CIDR}" >&2
    echo "${pod_ips}" >&2
    return 1
  fi

  log "validated pod network CIDR on ${profile}: ${POD_CIDR}"
}

configure_bridge_cni_pod_cidr() {
  local profile="$1"

  log "configure bridge CNI subnet on ${profile}: ${POD_CIDR}"
  profile_ssh "${profile}" "
    set -e
    sudo sed -i -E 's#(\"subnet\"[[:space:]]*:[[:space:]]*\")[^\"]+(\".*)#\1${POD_CIDR}\2#' /etc/cni/net.d/1-k8s.conflist
    sudo sed -n '1,80p' /etc/cni/net.d/1-k8s.conflist
  "

  kc_logged "${profile}" -n kube-system delete pod -l k8s-app=kube-dns --ignore-not-found --wait=false
  kubectl --context "${profile}" -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=90s || true

  profile_ssh "${profile}" "
    sudo rm -rf /var/lib/cni/networks/bridge/*
    sudo ip link delete bridge 2>/dev/null || true
  "

  kc_logged "${profile}" -n kube-system rollout status deployment/coredns --timeout=180s
}

ensure_guest_default_route() {
  local profile="$1"
  local node_ip
  local gateway_ip

  node_ip="$(profile_private_ip "${profile}")"
  if [[ -z "${node_ip}" || "${node_ip}" != *.*.*.* ]]; then
    log "skip guest default route repair for ${profile}: private IP unavailable"
    return 0
  fi

  gateway_ip="${node_ip%.*}.1"
  log "ensure guest default route on ${profile}: default via ${gateway_ip} dev eth0"
  if ! profile_ssh "${profile}" "sudo ip route replace default via '${gateway_ip}' dev eth0"; then
    log "failed to repair guest default route on ${profile}; continuing so diagnostics can show the actual cluster state"
    return 0
  fi

  profile_ssh "${profile}" "ip route show default || true" || true
}

repair_profile_libvirt_network() {
  local profile="$1"
  local private_ip
  local network="mk-${profile}"
  local gateway_ip
  local active_state

  if [[ "${MINIKUBE_DRIVER}" != "kvm2" ]]; then
    return 0
  fi

  private_ip="$(profile_private_ip "${profile}")"
  if [[ -z "${private_ip}" || "${private_ip}" != *.*.*.* ]]; then
    log "skip profile libvirt network repair for ${profile}: node IP unavailable"
    return 0
  fi

  gateway_ip="${private_ip%.*}.1"
  if ! virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" >/dev/null 2>&1; then
    log "skip profile libvirt network repair for ${profile}: ${network} not found"
    return 0
  fi

  active_state="$(virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" | awk '/Active:/ {print $2}' || true)"
  if [[ "${active_state}" == "yes" ]]; then
    log "skip DHCP gateway rewrite for active profile network ${network}; guest route will be repaired without disconnecting the VM"
  else
    log "repair profile libvirt network ${network}: dhcp gateway=${gateway_ip}"
    repair_libvirt_network_dhcp_gateway "${network}" "${gateway_ip}"
  fi
  ensure_libvirt_network_bridge_up "${network}"
}

ensure_kvm_network() {
  if [[ "${MINIKUBE_DRIVER}" != "kvm2" ]]; then
    echo "MINIKUBE_DRIVER must be kvm2 for this lab, got: ${MINIKUBE_DRIVER}" >&2
    echo "refusing to start minikube with qemu/builtin networking because Submariner endpoints would collide" >&2
    return 1
  fi

  require_cmd virsh
  require_kvm_access

  if grep -qi 'microsoft.*wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    log "WSL detected with MINIKUBE_DRIVER=kvm2; libvirt DHCP may fail in this environment"
  fi
}

start_cluster() {
  local profile="$1"
  local force_flag=()
  local iso_url_flag=()
  local apiserver_cert_flags=()
  local kvm_flags=()
  local pod_cidr_prefix="${POD_CIDR#*/}"

  if use_existing_cluster_if_ready "${profile}"; then
    return 0
  fi

  if [[ "${MINIKUBE_DRIVER}" == "qemu" || "${MINIKUBE_DRIVER}" == "qemu2" || "${MINIKUBE_DRIVER}" == "kvm2" ]]; then
    force_flag+=(--force)
  fi

  if [[ "${MINIKUBE_DRIVER}" == "kvm2" ]]; then
    kvm_flags+=(--kvm-qemu-uri="${MINIKUBE_KVM_QEMU_URI}")
  fi

  if [[ -n "${MINIKUBE_ISO_URL}" ]]; then
    iso_url_flag+=(--iso-url="${MINIKUBE_ISO_URL}")
  fi

  if [[ -n "${MINIKUBE_APISERVER_IPS:-}" ]]; then
    apiserver_cert_flags+=(--apiserver-ips="${MINIKUBE_APISERVER_IPS}")
  fi

  if [[ -n "${MINIKUBE_APISERVER_NAME:-}" ]]; then
    apiserver_cert_flags+=(--apiserver-name="${MINIKUBE_APISERVER_NAME}")
  fi

  if [[ -n "${MINIKUBE_APISERVER_NAMES:-}" ]]; then
    apiserver_cert_flags+=(--apiserver-names="${MINIKUBE_APISERVER_NAMES}")
  fi

  log "start minikube profile ${profile}"
  log "minikube driver=${MINIKUBE_DRIVER} kubernetes=${KUBERNETES_VERSION} runtime=${CONTAINER_RUNTIME}"
  log "minikube resources cpus=${MINIKUBE_CPUS} memory=${MINIKUBE_MEMORY} disk=${MINIKUBE_DISK_SIZE} nodes=${MINIKUBE_NODES} extraDisks=${MINIKUBE_EXTRA_DISKS}"
  log "minikube network podCIDR=${POD_CIDR} nodeCIDRMask=${pod_cidr_prefix} serviceCIDR=${SERVICE_CIDR} serviceDNS=${SERVICE_DNS_IP}"
  if [[ "${MINIKUBE_DRIVER}" == "kvm2" ]]; then
    log "minikube kvm qemuURI=${MINIKUBE_KVM_QEMU_URI}; per-profile libvirt networks are intentionally isolated"
  fi
  log "minikube apiserver cert ips=${MINIKUBE_APISERVER_IPS} name=${MINIKUBE_APISERVER_NAME} names=${MINIKUBE_APISERVER_NAMES}"
  log "minikube home=${MINIKUBE_HOME}"
  log "minikube start args: --profile=${profile} --driver=${MINIKUBE_DRIVER} --force --container-runtime=${CONTAINER_RUNTIME} --kubernetes-version=${KUBERNETES_VERSION} --service-cluster-ip-range=${SERVICE_CIDR} --extra-config=kubeadm.node-name=${profile} --extra-config=kubeadm.pod-network-cidr=${POD_CIDR} --extra-config=controller-manager.node-cidr-mask-size-ipv4=${pod_cidr_prefix}"

  local start_args=(
    --driver="${MINIKUBE_DRIVER}"
    --container-runtime="${CONTAINER_RUNTIME}"
    --kubernetes-version="${KUBERNETES_VERSION}"
    --cpus="${MINIKUBE_CPUS}"
    --memory="${MINIKUBE_MEMORY}"
    --disk-size="${MINIKUBE_DISK_SIZE}"
    --extra-disks="${MINIKUBE_EXTRA_DISKS}"
    --nodes="${MINIKUBE_NODES}"
    --service-cluster-ip-range="${SERVICE_CIDR}"
    --extra-config=kubeadm.pod-network-cidr="${POD_CIDR}"
    --extra-config=controller-manager.cluster-cidr="${POD_CIDR}"
    --extra-config=controller-manager.node-cidr-mask-size-ipv4="${pod_cidr_prefix}"
    --extra-config=kubeadm.node-name="${profile}"
    --extra-config=apiserver.service-cluster-ip-range="${SERVICE_CIDR}"
    --extra-config=kubelet.cluster-dns="${SERVICE_DNS_IP}"
    "${force_flag[@]}"
    "${iso_url_flag[@]}"
    "${kvm_flags[@]}"
    "${apiserver_cert_flags[@]}"
  )

  if ! start_minikube_cluster "${profile}" "${start_args[@]}"; then
    echo "minikube start failed for ${profile}" >&2
    dump_minikube_diagnostics "${profile}" >&2
    log "cleaning up ${profile} and retrying minikube start once"
    cleanup_stale_cluster "${profile}"

    if ! start_minikube_cluster "${profile}" "${start_args[@]}"; then
      echo "minikube start failed for ${profile} after retry" >&2
      dump_minikube_diagnostics "${profile}" >&2
      return 1
    fi
  fi

  sync_profile_kubeconfig "${profile}"
  repair_profile_libvirt_network "${profile}"
  ensure_guest_default_route "${profile}"
  ensure_host_nat_for_profile "${profile}"
  configure_bridge_cni_pod_cidr "${profile}"
  ensure_isolated_node_internal_ip "${profile}"
  wait_for_node_ready "${profile}"

  kc_logged "${profile}" get nodes -o wide
  validate_pod_network_cidr "${profile}"
  validate_cluster_driver_and_ip "${profile}"
}

validate_cluster_driver_and_ip() {
  local profile="$1"
  local profile_config="${MINIKUBE_HOME}/.minikube/profiles/${profile}/config.json"
  local driver
  local node_ip
  local private_ip
  local expected_ip

  driver="$(awk -F: '/"Driver"/{gsub(/[",[:space:]]/, "", $2); print $2; exit}' "${profile_config}" 2>/dev/null || true)"
  node_ip="$(kubectl --context "${profile}" get node "${profile}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  private_ip="$(profile_private_ip "${profile}")"
  expected_ip="$(profile_internal_ip "${profile}")"

  log "validate ${profile}: driver=${driver:-unknown} internalIP=${node_ip:-unknown} isolatedIP=${expected_ip} profileIP=${private_ip:-unknown}"

  if [[ "${driver}" != "kvm2" ]]; then
    echo "invalid minikube driver for ${profile}: ${driver:-unknown} (expected kvm2)" >&2
    echo "qemu/qemu2 is not acceptable for this lab because it produces builtin 10.0.2.15 endpoints" >&2
    return 1
  fi

  if [[ -z "${node_ip}" || "${node_ip}" == "10.0.2.15" ]]; then
    echo "invalid node InternalIP for ${profile}: ${node_ip:-empty}" >&2
    echo "expected a libvirt-backed address, not qemu builtin 10.0.2.15" >&2
    return 1
  fi

  if [[ "${node_ip}" != "${expected_ip}" ]]; then
    echo "unexpected node InternalIP for ${profile}: ${node_ip}" >&2
    echo "expected isolated non-shared InternalIP: ${expected_ip}" >&2
    return 1
  fi
}

assert_internal_ips_are_not_directly_reachable() {
  local from_profile="$1"
  local target_ip="$2"

  if profile_ssh "${from_profile}" "timeout 2 ping -c 1 -W 1 '${target_ip}' >/dev/null 2>&1"; then
    echo "unexpected direct reachability from ${from_profile} to isolated InternalIP ${target_ip}" >&2
    return 1
  fi
}

ensure_kvm_network
start_cluster "${SOURCE_CLUSTER_PROFILE}"
start_cluster "${RECOVERY_CLUSTER_PROFILE}"

source_ip="$(kubectl --context "${SOURCE_CLUSTER_PROFILE}" get node "${SOURCE_CLUSTER_PROFILE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
recovery_ip="$(kubectl --context "${RECOVERY_CLUSTER_PROFILE}" get node "${RECOVERY_CLUSTER_PROFILE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
source_profile_ip="$(profile_private_ip "${SOURCE_CLUSTER_PROFILE}")"
recovery_profile_ip="$(profile_private_ip "${RECOVERY_CLUSTER_PROFILE}")"
if [[ "${source_ip}" == "${recovery_ip}" ]]; then
  echo "cluster node InternalIPs must be distinct, but both are ${source_ip}" >&2
  exit 1
fi
if [[ "${source_ip%.*}" != "${recovery_ip%.*}" ]]; then
  echo "cluster node InternalIPs must intentionally share a CIDR for this lab: ${source_ip}, ${recovery_ip}" >&2
  exit 1
fi
assert_internal_ips_are_not_directly_reachable "${SOURCE_CLUSTER_PROFILE}" "${recovery_ip}"
assert_internal_ips_are_not_directly_reachable "${RECOVERY_CLUSTER_PROFILE}" "${source_ip}"
ensure_host_forward_between_cidrs "${source_profile_ip%.*}.0/24" "${recovery_profile_ip%.*}.0/24"
log "validated isolated non-shared node InternalIPs: ${SOURCE_CLUSTER_PROFILE}=${source_ip}, ${RECOVERY_CLUSTER_PROFILE}=${recovery_ip}"
log "validated reachable kvm2 management/gateway underlay: ${SOURCE_CLUSTER_PROFILE}=${source_profile_ip}, ${RECOVERY_CLUSTER_PROFILE}=${recovery_profile_ip}"

log "clusters ready"
