#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v mise >/dev/null 2>&1; then
  if ! mise_env="$(mise env -s bash -C "${EXPERIMENT_DIR}")"; then
    echo "failed to load mise environment for ${EXPERIMENT_DIR}" >&2
    echo "run 'mise trust' in the repository root, then retry" >&2
    exit 1
  fi
  eval "${mise_env}"
fi

# Older versions of this lab used a shared kvm2 network named "overlap-cidr".
# If those MINIKUBE_* variables remain exported in the caller's shell, minikube
# still consumes them even though they are no longer defined in mise.toml.
unset MINIKUBE_KVM_NETWORK
unset MINIKUBE_HOST_ONLY_CIDR
unset MINIKUBE_KVM_NETWORK_BRIDGE
unset MINIKUBE_KVM_NETWORK_IP
unset MINIKUBE_KVM_NETWORK_NETMASK
unset MINIKUBE_KVM_NETWORK_DHCP_START
unset MINIKUBE_KVM_NETWORK_DHCP_END

required_env_vars=(
  SOURCE_CLUSTER_PROFILE
  RECOVERY_CLUSTER_PROFILE
  SOURCE_CLUSTER_ID
  RECOVERY_CLUSTER_ID
  BROKER_CONTEXT
  MINIKUBE_HOME
  MINIKUBE_VERSION
  KUBECTL_VERSION
  KUBERNETES_VERSION
  MINIKUBE_ISO_URL
  MINIKUBE_DRIVER
  MINIKUBE_KVM_QEMU_URI
  MINIKUBE_APISERVER_IPS
  MINIKUBE_APISERVER_NAME
  MINIKUBE_APISERVER_NAMES
  CONTAINER_RUNTIME
  MINIKUBE_CPUS
  MINIKUBE_MEMORY
  MINIKUBE_DISK_SIZE
  MINIKUBE_NODES
  MINIKUBE_EXTRA_DISKS
  CLUSTER_INTERNAL_IFACE
  CLUSTER_INTERNAL_CIDR
  SOURCE_CLUSTER_INTERNAL_IP
  RECOVERY_CLUSTER_INTERNAL_IP
  POD_CIDR
  SERVICE_CIDR
  SERVICE_DNS_IP
  BROKER_NAMESPACE
  BROKER_INFO_FILE
  BROKER_HOST
  BROKER_URL
  SUBCTL_CHECK_BROKER_CERTIFICATE
  GLOBALNET_CIDR_RANGE
  SOURCE_GLOBALNET_CIDR
  RECOVERY_GLOBALNET_CIDR
  SUBMARINER_CABLE_DRIVER
  SUBMARINER_HEALTH_CHECK
  SUBMARINER_USE_NFTABLES
  SUBCTL_VERSION
  ROOK_NAMESPACE
  ROOK_VERSION
  ROOK_CEPH_OPERATOR_IMAGE
  CEPH_CSI_OPERATOR_IMAGE
  CEPH_IMAGE
  BUSYBOX_IMAGE
  ROOK_CLUSTER_NAME
  ROOK_DATA_DIR
  ROOK_OSD_DEVICE_FILTER
  MIRRORED_POOL_NAME
  RBD_MIRROR_NAME
  STORAGE_CLASS_NAME
  TEST_NAMESPACE
  TEST_PVC_NAME
  TEST_POD_NAME
  GLOBALNET_TEST_NAMESPACE
  GLOBALNET_TEST_APP
  GLOBALNET_TEST_SERVICE
  GLOBALNET_TEST_CLIENT
  GLOBALNET_SOURCE_CONTEXT
  GLOBALNET_RECOVERY_CONTEXT
)

for required_env_var in "${required_env_vars[@]}"; do
  if [[ -z "${!required_env_var+x}" ]]; then
    echo "missing required environment variable: ${required_env_var}" >&2
    echo "load the repository mise.toml with 'mise exec -- <command>' or run through the lab scripts" >&2
    exit 1
  fi
done

optional_empty_env_vars=" MINIKUBE_ISO_URL MINIKUBE_APISERVER_IPS BROKER_HOST BROKER_URL "
for required_env_var in "${required_env_vars[@]}"; do
  if [[ "${optional_empty_env_vars}" == *" ${required_env_var} "* ]]; then
    continue
  fi

  if [[ -z "${!required_env_var}" ]]; then
    echo "required environment variable is empty: ${required_env_var}" >&2
    echo "check the repository mise.toml and reload it with 'mise exec -- <command>' or run through the lab scripts" >&2
    exit 1
  fi
done

for path_env_var in BROKER_INFO_FILE; do
  if [[ "${!path_env_var}" != /* ]]; then
    printf -v "${path_env_var}" '%s/%s' "${EXPERIMENT_DIR}" "${!path_env_var}"
    export "${path_env_var}"
  fi
done

STATE_DIR="${EXPERIMENT_DIR}/.state"
MANIFEST_DIR="${EXPERIMENT_DIR}/manifests"

mkdir -p "${STATE_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

format_command() {
  local first=1
  local arg

  for arg in "$@"; do
    if (( first == 0 )); then
      printf ' '
    fi
    printf '%q' "${arg}"
    first=0
  done
}

log_command() {
  log "+ $(format_command "$@")"
}

log_command_text() {
  log "+ $*"
}

run_logged() {
  log_command "$@"
  "$@"
}

minikube_cmd() {
  command minikube "$@"
}

profile_config_file() {
  local profile="$1"
  printf '%s/.minikube/profiles/%s/config.json\n' "${MINIKUBE_HOME}" "${profile}"
}

profile_private_ip() {
  local profile="$1"
  local profile_config

  profile_config="$(profile_config_file "${profile}")"
  awk -F: '/"Nodes"/{in_nodes=1} in_nodes && /"IP"/{gsub(/[",[:space:]]/, "", $2); print $2; exit}' "${profile_config}" 2>/dev/null || true
}

profile_api_server_port() {
  local profile="$1"
  local profile_config

  profile_config="$(profile_config_file "${profile}")"
  awk -F: '/"APIServerPort"/{gsub(/[^0-9]/, "", $2); print $2; exit}' "${profile_config}" 2>/dev/null || true
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "required command not found: ${cmd}" >&2
    exit 1
  fi
}

require_common_tools() {
  require_cmd kubectl
  require_cmd sed
  require_cmd base64
}

extract_libvirt_network_bridge() {
  local network="$1"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-dumpxml "${network}" 2>/dev/null \
    | sed -n "s/.*<bridge name='\\([^']*\\)'.*/\\1/p" \
    | head -n1
}

ensure_libvirt_network_bridge_up() {
  local network="$1"
  local bridge

  bridge="$(extract_libvirt_network_bridge "${network}" || true)"
  if [[ -z "${bridge}" ]]; then
    return 0
  fi

  if ip link show "${bridge}" >/dev/null 2>&1 && ! ip -br link show "${bridge}" | awk '{print $2}' | grep -q "UP"; then
    log "bringing libvirt bridge ${bridge} up for network ${network}"
    if ! ip link set "${bridge}" up; then
      log "failed to bring bridge ${bridge} up for network ${network}"
    fi
  fi
}

libvirt_network_dhcp_listener_exists() {
  local network="$1"
  local bridge

  bridge="$(extract_libvirt_network_bridge "${network}" || true)"
  if [[ -z "${bridge}" ]]; then
    return 1
  fi

  ss -lunp 2>/dev/null | grep -qE "0\\.0\\.0\\.0%${bridge}:67\\b"
}

ensure_libvirt_network_dhcp_listener() {
  local network="$1"
  local bridge
  local conf_file
  local connections

  if ! virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" >/dev/null 2>&1; then
    return 0
  fi

  if libvirt_network_dhcp_listener_exists "${network}"; then
    return 0
  fi

  connections="$(virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-dumpxml "${network}" 2>/dev/null | sed -n "s/.*<network connections='\\([0-9][0-9]*\\)'.*/\\1/p" | head -n1)"
  if [[ -n "${connections}" && "${connections}" != "0" ]]; then
    bridge="$(extract_libvirt_network_bridge "${network}" || true)"
    conf_file="/var/lib/libvirt/dnsmasq/${network}.conf"
    if [[ -n "${bridge}" && -f "${conf_file}" && -x /usr/sbin/dnsmasq ]]; then
      log "start dnsmasq for active libvirt network ${network} without detaching guests"
      VIR_BRIDGE_NAME="${bridge}" /usr/sbin/dnsmasq \
        --conf-file="${conf_file}" \
        --leasefile-ro \
        --dhcp-script=/usr/lib/libvirt/libvirt_leaseshelper >/dev/null 2>&1 || true
      if libvirt_network_dhcp_listener_exists "${network}"; then
        return 0
      fi
    fi
    log "libvirt network ${network} has active guest connections but no DHCP listener; not restarting it while guests are attached"
    return 0
  fi

  log "restart libvirt network ${network} to restore DHCP listener"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-destroy "${network}" >/dev/null 2>&1 || true
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-start "${network}" >/dev/null
  ensure_libvirt_network_bridge_up "${network}"
}

repair_libvirt_network_dhcp_gateway() {
  local network="$1"
  local gateway="$2"
  local active_state
  local tmp_src
  local tmp_new
  local changed="false"
  local has_code3
  local has_code3_gateway

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 not available; skip dhcp gateway repair for ${network}"
    return 0
  fi

  if ! virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" >/dev/null 2>&1; then
    return 0
  fi

  tmp_src="$(mktemp)"
  tmp_new="$(mktemp)"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-dumpxml "${network}" >"${tmp_src}"

  if grep -Eq "code=['\"]3['\"]" "${tmp_src}" && grep -Eq "value=['\"]${gateway}['\"]" "${tmp_src}"; then
    rm -f "${tmp_src}" "${tmp_new}"
    return 0
  fi

  has_code3="$(grep -Ec "code=['\"]3['\"]" "${tmp_src}" || true)"
  has_code3_gateway="$(grep -Ec "(code=['\"]3['\"].*value=['\"]${gateway}['\"]|value=['\"]${gateway}['\"].*code=['\"]3['\"])" "${tmp_src}" || true)"
  if [[ "${has_code3}" -eq 0 ]]; then
    python3 - "$gateway" "${tmp_src}" "${tmp_new}" <<'PY'
import xml.etree.ElementTree as ET
import sys

expected = sys.argv[1]
input_path = sys.argv[2]
output_path = sys.argv[3]

root = ET.parse(input_path).getroot()
for ip in root.findall("ip"):
    dhcp = ip.find("dhcp")
    if dhcp is None:
        continue
    option = ET.Element("option", code="3", value=expected)
    dhcp.append(option)

ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=False)
PY
    changed="true"
  elif [[ "${has_code3}" -gt 0 && "${has_code3_gateway}" -eq 0 ]]; then
    python3 - "$gateway" "${tmp_src}" "${tmp_new}" <<'PY'
import xml.etree.ElementTree as ET
import sys

expected = sys.argv[1]
input_path = sys.argv[2]
output_path = sys.argv[3]

root = ET.parse(input_path).getroot()
for ip in root.findall("ip"):
    dhcp = ip.find("dhcp")
    if dhcp is None:
        continue
    for option in dhcp.findall("option"):
        if option.attrib.get("code") == "3":
            option.attrib["value"] = expected
ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=False)
PY
    changed="true"
  fi

  if [[ "${changed}" != "true" ]]; then
    rm -f "${tmp_src}" "${tmp_new}"
    return 0
  fi

  active_state="$(virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-info "${network}" | awk '/Active:/ {print $2}' || true)"
  if [[ "${active_state}" == "yes" ]]; then
    log "skip DHCP gateway rewrite for active network ${network}; avoiding VM network detach"
    rm -f "${tmp_src}" "${tmp_new}"
    return 0
  fi

  log "redefining network ${network} to add DHCP gateway ${gateway} (previous active=${active_state})"
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-undefine "${network}" >/dev/null 2>&1 || true
  virsh --connect "${MINIKUBE_KVM_QEMU_URI}" net-define "${tmp_new}" >/dev/null

  rm -f "${tmp_src}" "${tmp_new}"
}

reset_overlap_nft_nat_once() {
  local nft_table="overlap_cidr_nat"

  if [[ "${OVERLAP_NFT_NAT_RESET_DONE:-false}" == "true" ]]; then
    return 0
  fi

  if command -v nft >/dev/null 2>&1; then
    nft delete table ip "${nft_table}" >/dev/null 2>&1 || true
    nft add table ip "${nft_table}" >/dev/null 2>&1 || true
    nft 'add chain ip '"${nft_table}"' postrouting { type nat hook postrouting priority srcnat; policy accept; }' >/dev/null 2>&1 || true
    nft 'add chain ip '"${nft_table}"' forward { type filter hook forward priority -50; policy accept; }' >/dev/null 2>&1 || true
  fi

  OVERLAP_NFT_NAT_RESET_DONE="true"
}

iptables_insert_unique() {
  local table="$1"
  local chain="$2"
  shift 2

  while iptables -t "${table}" -C "${chain}" "$@" >/dev/null 2>&1; do
    iptables -t "${table}" -D "${chain}" "$@" >/dev/null 2>&1 || break
  done
  iptables -t "${table}" -I "${chain}" 1 "$@"
}

host_outbound_interface() {
  ip route get 1.1.1.1 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

enable_host_ipv4_forwarding() {
  local outbound_if="${1:-}"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true
  if [[ -n "${outbound_if}" ]]; then
    sysctl -w "net.ipv4.conf.${outbound_if}.rp_filter=0" >/dev/null 2>&1 || true
  fi
}

ensure_host_nat_for_cidr() {
  local cidr="$1"
  local label="${2:-${cidr}}"
  local outbound_if
  local nft_table="overlap_cidr_nat"

  outbound_if="$(host_outbound_interface)"
  if [[ -z "${outbound_if}" ]]; then
    log "failed to detect outbound interface for ${label}; skip NAT repair for ${cidr}"
    return 0
  fi

  log "ensure host NAT for ${label}: ${cidr} via ${outbound_if}"
  enable_host_ipv4_forwarding "${outbound_if}"

  if command -v iptables >/dev/null 2>&1; then
    iptables_insert_unique nat POSTROUTING -s "${cidr}" -o "${outbound_if}" -j MASQUERADE
    iptables_insert_unique filter FORWARD -s "${cidr}" -o "${outbound_if}" -j ACCEPT
    iptables_insert_unique filter FORWARD -d "${cidr}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  fi

  if command -v nft >/dev/null 2>&1; then
    reset_overlap_nft_nat_once
    nft add rule ip "${nft_table}" postrouting ip saddr "${cidr}" oifname "${outbound_if}" masquerade >/dev/null 2>&1 || true
    nft add rule ip "${nft_table}" forward ip saddr "${cidr}" oifname "${outbound_if}" accept >/dev/null 2>&1 || true
    nft add rule ip "${nft_table}" forward ip daddr "${cidr}" ct state related,established accept >/dev/null 2>&1 || true
  fi
}

ensure_host_nat_for_profile() {
  local profile="$1"
  local private_ip

  private_ip="$(profile_private_ip "${profile}")"
  if [[ -z "${private_ip}" || "${private_ip}" != *.*.*.* ]]; then
    log "skip host NAT repair for ${profile}: node IP unavailable"
    return 0
  fi

  ensure_host_nat_for_cidr "${private_ip%.*}.0/24" "${profile}"
}

ensure_host_forward_between_cidrs() {
  local left_cidr="$1"
  local right_cidr="$2"
  local nft_table="overlap_cidr_nat"

  log "ensure host forwarding between ${left_cidr} and ${right_cidr}"
  enable_host_ipv4_forwarding

  if command -v iptables >/dev/null 2>&1; then
    iptables_insert_unique filter FORWARD -s "${left_cidr}" -d "${right_cidr}" -j ACCEPT
    iptables_insert_unique filter FORWARD -s "${right_cidr}" -d "${left_cidr}" -j ACCEPT
  fi

  if command -v nft >/dev/null 2>&1; then
    reset_overlap_nft_nat_once
    nft add rule ip "${nft_table}" forward ip saddr "${left_cidr}" ip daddr "${right_cidr}" accept >/dev/null 2>&1 || true
    nft add rule ip "${nft_table}" forward ip saddr "${right_cidr}" ip daddr "${left_cidr}" accept >/dev/null 2>&1 || true
  fi
}

dump_kvm_state() {
  log "KVM device diagnostics"
  run_logged ls -l /dev/kvm >&2 2>/dev/null || true
  run_logged stat -c '%A %U %G %t:%T %n' /dev/kvm >&2 2>/dev/null || true
  if command -v getfacl >/dev/null 2>&1; then
    run_logged getfacl -p /dev/kvm >&2 2>/dev/null || true
  fi
  run_logged id >&2 || true
  run_logged getent group kvm >&2 || true
  run_logged getent group libvirt >&2 || true
  if [[ -f /etc/libvirt/qemu.conf ]]; then
    log_command_text "grep -nE '^[[:space:]]*(user|group|dynamic_ownership)[[:space:]]*=' /etc/libvirt/qemu.conf"
    grep -nE '^[[:space:]]*(user|group|dynamic_ownership)[[:space:]]*=' /etc/libvirt/qemu.conf >&2 || true
  fi
}

require_kvm_access() {
  local err_file
  local rc

  if [[ "${MINIKUBE_DRIVER}" != "kvm2" ]]; then
    return 0
  fi

  if [[ ! -e /dev/kvm ]]; then
    echo "/dev/kvm is missing; kvm2 cannot start VMs on this host." >&2
    echo "Enable virtualization/nested virtualization for WSL or run on a host that exposes /dev/kvm." >&2
    dump_kvm_state
    return 1
  fi

  if [[ ! -c /dev/kvm ]]; then
    echo "/dev/kvm exists but is not a character device; kvm2 cannot use it." >&2
    dump_kvm_state
    return 1
  fi

  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "/dev/kvm is not readable/writable by the current user; kvm2 cannot use KVM acceleration." >&2
    if [[ "${EUID}" -ne 0 ]]; then
      echo "Add the user to the kvm group and start a new login session, for example: sudo usermod -aG kvm \"\${USER}\"" >&2
    else
      echo "Even root cannot access /dev/kvm; this is usually a host/WSL virtualization exposure issue, not a Unix group issue." >&2
    fi
    dump_kvm_state
    return 1
  fi

  if command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    err_file="$(mktemp)"
    rc=0
    timeout 3 qemu-system-x86_64 \
      -machine none \
      -accel kvm \
      -display none \
      -nodefaults \
      -no-user-config \
      -monitor none \
      -serial none \
      -S >/dev/null 2>"${err_file}" || rc=$?

    # If qemu stays alive until timeout, it opened KVM successfully.
    if [[ "${rc}" -eq 0 || "${rc}" -eq 124 ]]; then
      rm -f "${err_file}"
      return 0
    fi

    echo "qemu-system-x86_64 cannot initialize KVM; minikube kvm2 would fail the same way." >&2
    sed -n '1,80p' "${err_file}" >&2 || true
    rm -f "${err_file}"
    if [[ "${EUID}" -eq 0 ]]; then
      echo "Root also failed to initialize KVM, so fix WSL/host KVM exposure before rerunning make clusters." >&2
    fi
    dump_kvm_state
    return 1
  fi
}

kubeconfig_file() {
  local kubeconfig
  kubeconfig="${KUBECONFIG:-${HOME}/.kube/config}"
  # kubectl only accepts a single file here; use first path in case KUBECONFIG list is set.
  echo "${kubeconfig%%:*}"
}

sync_profile_kubeconfig() {
  local profile="$1"
  local profile_dir="${MINIKUBE_HOME}/.minikube/profiles/${profile}"
  local profile_config="${profile_dir}/config.json"
  local profile_ca="${MINIKUBE_HOME}/.minikube/ca.crt"
  local profile_client_crt="${profile_dir}/client.crt"
  local profile_client_key="${profile_dir}/client.key"
  local kubeconfig
  local api_server_port
  local api_server_url
  local driver
  local node_ip
  local node_port

  if [[ ! -f "${profile_config}" ]]; then
    echo "missing minikube profile config for ${profile}: ${profile_config}" >&2
    return 1
  fi

  driver="$(awk -F: '/"Driver"/{gsub(/[",[:space:]]/, "", $2); print $2; exit}' "${profile_config}")"
  api_server_port="$(profile_api_server_port "${profile}")"
  if [[ -z "${api_server_port}" ]]; then
    echo "failed to parse APIServerPort for ${profile}" >&2
    return 1
  fi

  api_server_url="https://localhost:${api_server_port}"
  if [[ "${driver}" == "kvm2" ]]; then
    node_ip="$(profile_private_ip "${profile}")"
    node_port="$(awk -F: '/"Nodes"/{in_nodes=1} in_nodes && /"Port"/{gsub(/[^0-9]/, "", $2); print $2; exit}' "${profile_config}")"
    if [[ -z "${node_port}" ]]; then
      node_port="8443"
    fi
    if [[ -z "${node_ip}" ]]; then
      echo "failed to parse kvm2 node IP for ${profile}: ${profile_config}" >&2
      return 1
    fi
    api_server_url="https://${node_ip}:${node_port}"
  fi

  if [[ ! -f "${profile_ca}" || ! -f "${profile_client_crt}" || ! -f "${profile_client_key}" ]]; then
    echo "missing certificates for ${profile}; skipping kubeconfig sync" >&2
    return 0
  fi

  kubeconfig="$(kubeconfig_file)"
  mkdir -p "$(dirname "${kubeconfig}")"

  log "sync kubeconfig context ${profile}: server=${api_server_url}"
  kubectl --kubeconfig="${kubeconfig}" config set-cluster "${profile}" \
    --server="${api_server_url}" \
    --certificate-authority="${profile_ca}" >/dev/null

  kubectl --kubeconfig="${kubeconfig}" config set-credentials "${profile}" \
    --client-certificate="${profile_client_crt}" \
    --client-key="${profile_client_key}" >/dev/null

  kubectl --kubeconfig="${kubeconfig}" config set-context "${profile}" \
    --cluster="${profile}" --user="${profile}" --namespace=default >/dev/null
}

require_minikube_version() {
  local expected="$1"
  local actual

  if [[ -z "${expected}" ]]; then
    return 0
  fi

  if ! actual="$(minikube_cmd version --short 2>/dev/null | awk 'NR==1 {print $1}')"; then
    echo "failed to execute 'minikube version --short'. install minikube ${expected} and retry" >&2
    exit 1
  fi

  actual="${actual##v}"
  expected="${expected#v}"

  if [[ -z "${actual}" ]]; then
    echo "failed to determine minikube version. install minikube ${expected} and retry" >&2
    exit 1
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    echo "unsupported minikube version: ${actual} (expected ${expected})" >&2
    echo "install and use minikube ${expected} before running this script" >&2
    exit 1
  fi
}

kc() {
  local context="$1"
  shift
  kubectl --context "${context}" "$@"
}

kc_logged() {
  local context="$1"
  shift

  log_command kubectl --context "${context}" "$@"
  kc "${context}" "$@"
}

subctl_logged() {
  log_command subctl "$@"
  subctl "$@"
}

wait_for_pod_label() {
  local context="$1"
  local namespace="$2"
  local selector="$3"
  local timeout="${4:-600s}"
  kc "${context}" -n "${namespace}" wait --for=condition=Ready pod -l "${selector}" --timeout="${timeout}"
}

wait_for_deployment() {
  local context="$1"
  local namespace="$2"
  local name="$3"
  local timeout="${4:-600s}"
  kc "${context}" -n "${namespace}" rollout status deployment/"${name}" --timeout="${timeout}"
}

wait_for_pvc_bound() {
  local context="$1"
  local namespace="$2"
  local name="$3"
  local timeout="${4:-600s}"
  kc "${context}" -n "${namespace}" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${name}" --timeout="${timeout}"
}

dump_sample_diagnostics() {
  local context="$1"

  echo "sample namespace resources on ${context}:" >&2
  kc_logged "${context}" -n "${TEST_NAMESPACE}" get pod,pvc,pv -o wide >&2 || true

  echo "sample pod describe on ${context}:" >&2
  kc_logged "${context}" -n "${TEST_NAMESPACE}" describe pod "${TEST_POD_NAME}" >&2 || true

  echo "sample pvc describe on ${context}:" >&2
  kc_logged "${context}" -n "${TEST_NAMESPACE}" describe pvc "${TEST_PVC_NAME}" >&2 || true

  echo "recent sample namespace events on ${context}:" >&2
  kc_logged "${context}" -n "${TEST_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp >&2 || true

  echo "rook ceph status on ${context}:" >&2
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephcluster,cephblockpool,cephrbdmirror -o wide >&2 || true
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get pods -o wide >&2 || true

  echo "rook/csi events on ${context}:" >&2
  log_command_text "kubectl --context ${context} -n ${ROOK_NAMESPACE} get events --sort-by=.metadata.creationTimestamp | tail -n 80" >&2
  kc "${context}" -n "${ROOK_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 80 >&2 || true
  log_command_text "kubectl --context ${context} -n kube-system get pods -o wide | grep -E 'csi|rook|rbd'" >&2
  kc "${context}" -n kube-system get pods -o wide | grep -E 'csi|rook|rbd' >&2 || true
  kc_logged "${context}" get storageclass,pv,volumeattachments >&2 || true
}

wait_for_pod_name_prefix() {
  local context="$1"
  local namespace="$2"
  local prefix="$3"
  local retries="${4:-120}"
  local sleep_seconds="${5:-5}"

  local pod_name=""
  local attempt=1
  while (( attempt <= retries )); do
    pod_name="$(
      kc "${context}" -n "${namespace}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | grep "^${prefix}" \
        | head -n1 || true
    )"

    if [[ -n "${pod_name}" ]]; then
      kc "${context}" -n "${namespace}" wait --for=condition=Ready "pod/${pod_name}" --timeout=600s
      return 0
    fi

    sleep "${sleep_seconds}"
    (( attempt += 1 ))
  done

  echo "timed out waiting for pod prefix ${prefix} in ${namespace} on ${context}" >&2
  return 1
}

wait_for_jsonpath_value() {
  local context="$1"
  local namespace="$2"
  local kind="$3"
  local name="$4"
  local jsonpath="$5"
  local expected="$6"
  local retries="${7:-120}"
  local sleep_seconds="${8:-5}"

  local value=""
  local attempt=1
  while (( attempt <= retries )); do
    value="$(kc "${context}" -n "${namespace}" get "${kind}" "${name}" -o "jsonpath=${jsonpath}" 2>/dev/null || true)"
    if [[ "${value}" == "${expected}" ]]; then
      return 0
    fi
    sleep "${sleep_seconds}"
    (( attempt += 1 ))
  done

  echo "timed out waiting for ${kind}/${name} jsonpath ${jsonpath} to become ${expected}; last value=${value}" >&2
  return 1
}

wait_for_nonempty_jsonpath() {
  local context="$1"
  local namespace="$2"
  local kind="$3"
  local name="$4"
  local jsonpath="$5"
  local retries="${6:-120}"
  local sleep_seconds="${7:-5}"

  local value=""
  local attempt=1
  while (( attempt <= retries )); do
    value="$(kc "${context}" -n "${namespace}" get "${kind}" "${name}" -o "jsonpath=${jsonpath}" 2>/dev/null || true)"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
    sleep "${sleep_seconds}"
    (( attempt += 1 ))
  done

  echo "timed out waiting for ${kind}/${name} jsonpath ${jsonpath}" >&2
  return 1
}

cluster_node_name() {
  local context="$1"
  kc "${context}" get nodes -o jsonpath='{.items[0].metadata.name}'
}

apply_template() {
  local template="$1"
  local cluster_id="${2:-}"
  local node_name="${3:-}"

  sed \
    -e "s|__ROOK_CLUSTER_NAME__|${ROOK_CLUSTER_NAME}|g" \
    -e "s|__ROOK_NAMESPACE__|${ROOK_NAMESPACE}|g" \
    -e "s|__CLUSTER_ID__|${cluster_id}|g" \
    -e "s|__CEPH_IMAGE__|${CEPH_IMAGE}|g" \
    -e "s|__ROOK_DATA_DIR__|${ROOK_DATA_DIR}|g" \
    -e "s#__ROOK_OSD_DEVICE_FILTER__#${ROOK_OSD_DEVICE_FILTER}#g" \
    -e "s|__NODE_NAME__|${node_name}|g" \
    -e "s|__MIRRORED_POOL_NAME__|${MIRRORED_POOL_NAME}|g" \
    -e "s|__RBD_MIRROR_NAME__|${RBD_MIRROR_NAME}|g" \
    -e "s|__STORAGE_CLASS_NAME__|${STORAGE_CLASS_NAME}|g" \
    -e "s|__TEST_NAMESPACE__|${TEST_NAMESPACE}|g" \
    -e "s|__TEST_PVC_NAME__|${TEST_PVC_NAME}|g" \
    -e "s|__TEST_POD_NAME__|${TEST_POD_NAME}|g" \
    -e "s|__GLOBALNET_TEST_NAMESPACE__|${GLOBALNET_TEST_NAMESPACE}|g" \
    -e "s|__GLOBALNET_TEST_APP__|${GLOBALNET_TEST_APP}|g" \
    -e "s|__GLOBALNET_TEST_SERVICE__|${GLOBALNET_TEST_SERVICE}|g" \
    "${template}"
}

apply_manifest() {
  local context="$1"
  local template="$2"
  local cluster_id="${3:-}"
  local node_name="${4:-}"

  apply_template "${template}" "${cluster_id}" "${node_name}" | kc "${context}" apply -f -
}

rook_release_base() {
  printf 'https://raw.githubusercontent.com/rook/rook/%s/deploy/examples' "${ROOK_VERSION}"
}

rewrite_rook_manifest() {
  sed \
    -e "s|docker.io/rook/ceph:${ROOK_VERSION}|${ROOK_CEPH_OPERATOR_IMAGE}|g" \
    -e "s|quay.io/cephcsi/ceph-csi-operator:[^[:space:]\"']*|${CEPH_CSI_OPERATOR_IMAGE}|g" \
    -e "s|quay.io/ceph/ceph:v[0-9][^[:space:]\"']*|${CEPH_IMAGE}|g" \
    -e 's|^\([[:space:]]*ROOK_CSI_ENABLE_CEPHFS:[[:space:]]*\).*|\1"false"|'
}

apply_rook_example() {
  local context="$1"
  local filename="$2"
  local base
  base="$(rook_release_base)"

  log "apply rook example ${filename} on ${context}"
  curl -fsSL "${base}/${filename}" | rewrite_rook_manifest | kc "${context}" apply -f -
}

remove_cephfs_csi_workloads() {
  local context="$1"

  log "remove cephfs csi workloads on ${context}"
  kc "${context}" -n "${ROOK_NAMESPACE}" delete deployment,daemonset \
    -l 'app in (csi-cephfsplugin,csi-cephfsplugin-provisioner)' \
    --ignore-not-found
  kc "${context}" -n "${ROOK_NAMESPACE}" delete \
    deployment/rook-ceph.cephfs.csi.ceph.com-ctrlplugin \
    daemonset/rook-ceph.cephfs.csi.ceph.com-nodeplugin \
    --ignore-not-found
}

install_rook_operator() {
  local context="$1"

  log "install rook operator on ${context}"
  log "rook images: operator=${ROOK_CEPH_OPERATOR_IMAGE} csi-operator=${CEPH_CSI_OPERATOR_IMAGE} ceph=${CEPH_IMAGE}"
  apply_rook_example "${context}" crds.yaml
  apply_rook_example "${context}" common.yaml
  apply_rook_example "${context}" csi-operator.yaml
  apply_rook_example "${context}" operator.yaml
  wait_for_deployment "${context}" "${ROOK_NAMESPACE}" "rook-ceph-operator" "900s"
  remove_cephfs_csi_workloads "${context}"
}

install_rook_toolbox() {
  local context="$1"

  log "install rook toolbox on ${context}"
  apply_rook_example "${context}" toolbox.yaml
  wait_for_deployment "${context}" "${ROOK_NAMESPACE}" "rook-ceph-tools" "600s"
}

rook_toolbox() {
  local context="$1"
  shift
  kc "${context}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- "$@"
}

rook_toolbox_logged() {
  local context="$1"
  shift

  log_command kubectl --context "${context}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- "$@"
  rook_toolbox "${context}" "$@"
}

ensure_namespace() {
  local context="$1"
  local namespace="$2"
  kc "${context}" get namespace "${namespace}" >/dev/null 2>&1 || kc "${context}" create namespace "${namespace}"
}
