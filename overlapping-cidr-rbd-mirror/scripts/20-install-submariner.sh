#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd subctl
require_common_tools

mkdir -p "$(dirname "${BROKER_INFO_FILE}")"
rm -f "${BROKER_INFO_FILE}"
SUBCTL_GATEWAY_WAIT_RETRIES="${SUBCTL_GATEWAY_WAIT_RETRIES:-60}"
SUBCTL_GATEWAY_WAIT_SECONDS="${SUBCTL_GATEWAY_WAIT_SECONDS:-5}"
SUBCTL_GATEWAY_POD_WAIT_RETRIES="${SUBCTL_GATEWAY_POD_WAIT_RETRIES:-60}"
SUBCTL_GATEWAY_POD_WAIT_SECONDS="${SUBCTL_GATEWAY_POD_WAIT_SECONDS:-5}"
SUBCTL_CONNECTION_WAIT_RETRIES="${SUBCTL_CONNECTION_WAIT_RETRIES:-60}"
SUBCTL_CONNECTION_WAIT_SECONDS="${SUBCTL_CONNECTION_WAIT_SECONDS:-5}"
SUBMARINER_OPERATOR_NAMESPACE="${SUBMARINER_OPERATOR_NAMESPACE:-submariner-operator}"
SUBCTL_CHECK_BROKER_CERTIFICATE="${SUBCTL_CHECK_BROKER_CERTIFICATE:-true}"

gateway_public_ip() {
  local context="$1"
  local private_ip

  private_ip="$(profile_private_ip "${context}")"
  if [[ -z "${private_ip}" ]]; then
    echo "failed to determine kvm2 profile IP for ${context}" >&2
    return 1
  fi
  printf '%s\n' "${private_ip}"
}

resolve_broker_api_url() {
  local host_ip=""
  local host_port=""
  local context_api_server=""
  local api_server_host=""
  local api_server_port=""
  local kubeconfig
  local broker_context

  if [[ -n "${BROKER_URL:-}" ]]; then
    return 0
  fi

  broker_context="${BROKER_CONTEXT}"
  kubeconfig="$(kubeconfig_file)"

  context_api_server="$(kubectl --kubeconfig="${kubeconfig}" config view --raw --minify --context "${broker_context}" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ -n "${context_api_server}" ]]; then
    host_port="${context_api_server#*://}"
    host_port="${host_port%%/*}"
    if [[ "${host_port}" == *:* ]]; then
      api_server_host="${host_port%%:*}"
      api_server_port="${host_port##*:}"
    else
      api_server_host="${host_port}"
    fi
  fi

  if [[ -n "${api_server_port}" ]]; then
    host_port="${api_server_port}"
  fi

  if [[ -z "${host_port}" ]]; then
    host_port="$(profile_api_server_port "${BROKER_CONTEXT}")"
  fi

  if [[ -n "${BROKER_HOST:-}" ]]; then
    host_ip="${BROKER_HOST}"
  fi

  if [[ -z "${host_ip}" && -n "${api_server_host}" && "${api_server_host}" != "localhost" && "${api_server_host}" != "127.0.0.1" ]]; then
    host_ip="${api_server_host}"
  fi

  if [[ -z "${host_ip}" && "${MINIKUBE_DRIVER}" == "kvm2" ]]; then
    host_ip="$(profile_private_ip "${BROKER_CONTEXT}")"
  fi

  if [[ -z "${host_ip}" || -z "${host_port}" ]]; then
    echo "failed to resolve directly reachable broker API endpoint for ${BROKER_CONTEXT}" >&2
    echo "run 'make clusters' first, or set BROKER_HOST/BROKER_URL explicitly" >&2
    return 1
  fi

  BROKER_URL="https://${host_ip}:${host_port}"
  export BROKER_URL
  log "using directly reachable BROKER_URL=${BROKER_URL} for ${BROKER_CONTEXT}"
}

validate_tunnel_prereqs() {
  local source_private
  local recovery_private

  if [[ "${MINIKUBE_DRIVER}" != "kvm2" ]]; then
    echo "MINIKUBE_DRIVER must be kvm2 for this lab, got: ${MINIKUBE_DRIVER}" >&2
    return 1
  fi

  source_private="$(kc "${SOURCE_CLUSTER_PROFILE}" get node "${SOURCE_CLUSTER_PROFILE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  recovery_private="$(kc "${RECOVERY_CLUSTER_PROFILE}" get node "${RECOVERY_CLUSTER_PROFILE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  if [[ -z "${source_private}" || -z "${recovery_private}" ]]; then
    echo "failed to determine node InternalIP for gateway endpoint uniqueness check" >&2
    return 1
  fi

  if [[ "${source_private}" == "${recovery_private}" ]]; then
    echo "gateway node InternalIPs are identical: ${source_private}" >&2
    echo "gateway endpoint IPs must be distinct underlay addresses; Pod/Service CIDRs are the overlapping networks in this lab." >&2
    return 1
  fi

  local source_public
  local recovery_public
  source_public="$(gateway_public_ip "${SOURCE_CLUSTER_PROFILE}")"
  recovery_public="$(gateway_public_ip "${RECOVERY_CLUSTER_PROFILE}")"
  if [[ -z "${source_public}" || -z "${recovery_public}" || "${source_public}" == "${recovery_public}" ]]; then
    echo "gateway public underlay IPs must be distinct: source=${source_public:-empty}, recovery=${recovery_public:-empty}" >&2
    return 1
  fi
}

resolve_broker_api_url
validate_tunnel_prereqs

log "deploy broker on ${BROKER_CONTEXT}"
deploy_broker_cmd() {
  local broker_opts=()

  if [[ -n "${BROKER_URL:-}" ]]; then
    broker_opts+=(--broker-url "${BROKER_URL}")
  fi

  if subctl deploy-broker --help | grep -q -- '--broker-namespace'; then
    log_command subctl deploy-broker \
      --context "${BROKER_CONTEXT}" \
      --broker-namespace "${BROKER_NAMESPACE}" \
      "${broker_opts[@]}" \
      --globalnet \
      --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
    subctl deploy-broker \
      --context "${BROKER_CONTEXT}" \
      --broker-namespace "${BROKER_NAMESPACE}" \
      "${broker_opts[@]}" \
      --globalnet \
      --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
    return
  fi

  if subctl deploy-broker --help | grep -q -- '--namespace '; then
    log_command subctl deploy-broker \
      --context "${BROKER_CONTEXT}" \
      --namespace "${BROKER_NAMESPACE}" \
      "${broker_opts[@]}" \
      --globalnet \
      --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
    subctl deploy-broker \
      --context "${BROKER_CONTEXT}" \
      --namespace "${BROKER_NAMESPACE}" \
      "${broker_opts[@]}" \
      --globalnet \
      --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
    return
  fi

  log_command subctl deploy-broker \
    --context "${BROKER_CONTEXT}" \
    "${broker_opts[@]}" \
    --globalnet \
    --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
  subctl deploy-broker \
    --context "${BROKER_CONTEXT}" \
    "${broker_opts[@]}" \
    --globalnet \
    --globalnet-cidr-range "${GLOBALNET_CIDR_RANGE}"
}

(
  cd "$(dirname "${BROKER_INFO_FILE}")"
  deploy_broker_cmd
)

if [[ ! -f "${BROKER_INFO_FILE}" ]]; then
  echo "broker info file was not generated: ${BROKER_INFO_FILE}" >&2
  exit 1
fi

join_cluster() {
  local context="$1"
  local cluster_id="$2"
  local globalnet_cidr="$3"
  local join_opts=()
  local public_ip

  if [[ -n "${BROKER_URL:-}" ]]; then
    join_opts+=(--broker-url "${BROKER_URL}")
  fi

  if [[ "${SUBCTL_CHECK_BROKER_CERTIFICATE}" == "false" ]]; then
    join_opts+=(--check-broker-certificate=false)
  fi

  if [[ "${SUBMARINER_HEALTH_CHECK}" == "false" ]]; then
    join_opts+=(--health-check=false)
  fi

  if [[ "${context}" == "${RECOVERY_CLUSTER_PROFILE}" ]]; then
    join_opts+=(--preferred-server)
  fi

  log "join ${context} to broker with globalnet cidr ${globalnet_cidr}"
  if ! kubectl --context "${context}" get nodes --request-timeout=5s >/dev/null 2>&1; then
    echo "cluster ${context} is not accessible via kubectl. Run 'make clusters' first." >&2
    return 1
  fi

  public_ip="$(gateway_public_ip "${context}")"
  if [[ -z "${public_ip}" ]]; then
    echo "failed to determine gateway public IP for ${context}" >&2
    return 1
  fi

  log "annotate ${context} gateway node: public-ip=ipv4:${public_ip}; kvm2 uses isolated per-profile libvirt underlay with --natt=false"
  kc_logged "${context}" annotate node "${context}" \
    "gateway.submariner.io/public-ip=ipv4:${public_ip}" \
    gateway.submariner.io/udp-port- \
    gateway.submariner.io/natt-discovery-port- \
    --overwrite
  join_opts+=(--natt=false)

  log "run k8s version diagnosis on ${context}"
  if ! subctl diagnose k8s-version --context "${context}" >/dev/null 2>&1; then
    echo "kubernetes version compatibility checks failed for ${context}" >&2
    subctl diagnose k8s-version --context "${context}" || true
    return 1
  fi

  log_command subctl join "${BROKER_INFO_FILE}" \
    --context "${context}" \
    --clusterid "${cluster_id}" \
    --cable-driver "${SUBMARINER_CABLE_DRIVER}" \
    --clustercidr "${POD_CIDR}" \
    --servicecidr "${SERVICE_CIDR}" \
    "${join_opts[@]}" \
    --globalnet \
    --globalnet-cidr "${globalnet_cidr}"
  subctl join "${BROKER_INFO_FILE}" \
    --context "${context}" \
    --clusterid "${cluster_id}" \
    --cable-driver "${SUBMARINER_CABLE_DRIVER}" \
    --clustercidr "${POD_CIDR}" \
    --servicecidr "${SERVICE_CIDR}" \
    "${join_opts[@]}" \
    --globalnet \
    --globalnet-cidr "${globalnet_cidr}"

  if ! wait_for_submariner_resource "${context}"; then
    return 1
  fi

  configure_packet_filter_driver "${context}"
}

configure_packet_filter_driver() {
  local context="$1"
  local cm
  local pod

  if [[ "${SUBMARINER_USE_NFTABLES}" != "false" ]]; then
    return 0
  fi

  log "configure submariner packet filter driver on ${context}: use-nftables=false"
  for cm in submariner-global submariner-routeagent; do
    if ! kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get configmap "${cm}" >/dev/null 2>&1; then
      kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" create configmap "${cm}" >/dev/null
    fi

    kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" patch configmap "${cm}" \
      --type merge \
      -p '{"data":{"use-nftables":"false"}}' >/dev/null
  done

  log "restart submariner gateway/routeagent/globalnet pods on ${context} to pick up endpoint and packet filter config"
  while read -r pod; do
    [[ -z "${pod}" ]] && continue
    kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" delete pod "${pod}" --ignore-not-found=true
  done < <(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$1 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)-/ {print $1}')
}

wait_for_submariner_resource() {
  local context="$1"
  local attempt=1
  local max_retries=60
  local sleep_seconds=5

  while (( attempt <= max_retries )); do
    if kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get submariner submariner >/dev/null 2>&1; then
      return 0
    fi
    log "submariner custom resource not found on ${context} (${attempt}/${max_retries}), retrying"
    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "submariner custom resource was not created in submariner-operator namespace on ${context}"
  echo
  echo "submariner-operator resources:"
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get all || true
  echo
  echo "subctl deployment diagnostics:"
  subctl_logged diagnose deployment --context "${context}" || true
  return 1
}

wait_for_gateways() {
  local context="$1"
  local attempt=1
  local show_rc
  local output

  log "wait for submariner gateways on ${context}"
  while (( attempt <= SUBCTL_GATEWAY_WAIT_RETRIES )); do
    if ! output="$(subctl show gateways --context "${context}" 2>&1)"; then
      show_rc=$?
    else
      show_rc=0
    fi

    if [[ -z "${output}" ]]; then
      output="no gateway status output from subctl show gateways"
    fi

    if (( show_rc != 0 )); then
      log "subctl show gateways failed on ${context} (attempt ${attempt}/${SUBCTL_GATEWAY_WAIT_RETRIES})"
      log "${output}"
      sleep "${SUBCTL_GATEWAY_WAIT_SECONDS}"
      ((attempt += 1))
      continue
    fi

    if ! grep -Ei -q "no .*gateways" <<<"${output}"; then
      log "gateways detected on ${context}"
      return 0
    fi

    if (( attempt == 1 )); then
      if ! wait_for_gateway_pods "${context}"; then
        echo "submariner gateway/route-agent pods did not become ready on ${context}; stopping early"
        echo
        echo "submariner components in all namespaces:"
        log_command_text "kubectl --context ${context} get pods -A --no-headers | grep submariner"
        kc "${context}" get pods -A --no-headers | grep submariner | sed '/^$/d' || true
        echo
        echo "subctl deployment diagnostics:"
        subctl_logged diagnose deployment --context "${context}" || true
        return 1
      fi
    fi

    log "gateways not detected on ${context} yet (${attempt}/${SUBCTL_GATEWAY_WAIT_RETRIES}), retrying"
    sleep "${SUBCTL_GATEWAY_WAIT_SECONDS}"
    ((attempt += 1))
  done

  echo "timed out waiting for gateways on ${context}. last output:"
  echo "${output}"
  echo
  echo "submariner components in all namespaces:"
  log_command_text "kubectl --context ${context} get pods -A --no-headers | grep submariner"
  kc "${context}" get pods -A --no-headers | grep submariner | sed '/^$/d' || true
  echo
  echo "submariner gateway resources:"
  subctl_logged show gateways --context "${context}" || true
  echo
  echo "subctl deployment diagnostics:"
  subctl_logged diagnose deployment --context "${context}" || true
  echo
  for pod in $(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers | awk '$1 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)/ {print $1}'); do
    echo "logs for ${pod}:"
    kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" logs "${pod}" --all-containers --tail=120 || true
    echo
  done
  echo "operator state and submariner CR:"
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get all || true
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get submariner 2>/dev/null || true
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get submariner submariner -o yaml 2>/dev/null || true
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" logs deployment/submariner-operator --all-containers --tail=200 || true
  return 1
}

wait_for_gateway_pods() {
  local context="$1"
  local attempt=1
  local line
  local name
  local ready

  log "wait for submariner gateway pods on ${context} (namespace: ${SUBMARINER_OPERATOR_NAMESPACE})"
  while (( attempt <= SUBCTL_GATEWAY_POD_WAIT_RETRIES )); do
    local gateway_ready=0
    local routeagent_ready=0

    while IFS=$'\n' read -r line; do
      [[ -z "${line}" ]] && continue
      read -r name ready _ <<<"${line}"

      if [[ "${name}" == submariner-gateway-* ]] && [[ "${ready}" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
          gateway_ready=1
        fi
      fi

      if [[ "${name}" == submariner-routeagent-* || "${name}" == submariner-route-agent-* ]] && [[ "${ready}" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
          routeagent_ready=1
        fi
      fi
    done < <(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers 2>/dev/null || true)

    if (( gateway_ready == 1 )) && (( routeagent_ready == 1 )); then
      log "submariner gateway and route-agent pods are ready on ${context}"
      return 0
    fi

    log "submariner gateway/route-agent pods not ready on ${context} yet (${attempt}/${SUBCTL_GATEWAY_POD_WAIT_RETRIES}), retrying"
    sleep "${SUBCTL_GATEWAY_POD_WAIT_SECONDS}"
    ((attempt += 1))
  done

  echo "timed out waiting for submariner gateway/route-agent pods on ${context}."
  echo
  echo "submariner-operator pods (${SUBMARINER_OPERATOR_NAMESPACE}):"
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers || true
  echo
  for pod in $(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers | awk '$1 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)/ {print $1}'); do
    echo "logs for ${pod}:"
    kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" logs "${pod}" --all-containers --tail=120 || true
    echo
  done
  if [[ -z "$(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers | awk '$1 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)/ {print $1}')" ]]; then
    echo "no submariner gateway/routeagent/globalnet pods exist in namespace ${SUBMARINER_OPERATOR_NAMESPACE}"
  fi
  echo
  echo "gateway/routeagent/globalnet pods in all namespaces (manual check):"
  log_command_text "kubectl --context ${context} get pods -A --no-headers | awk '\$2 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)-/ {print}'"
  kc "${context}" get pods -A --no-headers 2>/dev/null | awk '$2 ~ /^submariner-(gateway|routeagent|route-agent|globalnet)-/ {print}' || true
  echo
  echo "cluster nodes and submariner labels:"
  kc_logged "${context}" get nodes --no-headers -L submariner.io/gateway -L submariner.io/preferred -L node-role.kubernetes.io/control-plane -L kubernetes.io/arch || true
  return 1
}

join_cluster "${SOURCE_CLUSTER_PROFILE}" "${SOURCE_CLUSTER_ID}" "${SOURCE_GLOBALNET_CIDR}"
join_cluster "${RECOVERY_CLUSTER_PROFILE}" "${RECOVERY_CLUSTER_ID}" "${RECOVERY_GLOBALNET_CIDR}"

wait_for_gateways "${SOURCE_CLUSTER_PROFILE}"
wait_for_gateways "${RECOVERY_CLUSTER_PROFILE}"

wait_for_connections() {
  local context="$1"
  local attempt=1
  local output
  local show_rc

  log "wait for submariner connections on ${context}"
  while (( attempt <= SUBCTL_CONNECTION_WAIT_RETRIES )); do
    if ! output="$(subctl show connections --context "${context}" 2>&1)"; then
      show_rc=$?
    else
      show_rc=0
    fi

    if (( show_rc == 0 )) && grep -Eq '\bconnected\b' <<<"${output}" && ! grep -Eq '\b(connecting|error)\b' <<<"${output}"; then
      printf '%s\n' "${output}"
      return 0
    fi

    log "submariner connections not ready on ${context} yet (${attempt}/${SUBCTL_CONNECTION_WAIT_RETRIES})"
    if (( attempt == 1 || attempt % 12 == 0 )); then
      printf '%s\n' "${output}"
    fi
    sleep "${SUBCTL_CONNECTION_WAIT_SECONDS}"
    ((attempt += 1))
  done

  echo "timed out waiting for connected submariner connections on ${context}. last output:"
  printf '%s\n' "${output}"
  return 1
}

dump_connection_diagnostics() {
  local context="$1"
  local pod

  echo
  echo "submariner endpoint summary on ${context}:"
  subctl_logged show endpoints --context "${context}" || true
  echo
  echo "submariner gateway summary on ${context}:"
  subctl_logged show gateways --context "${context}" || true
  echo
  echo "submariner resources on ${context}:"
  kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get gateways,endpoints,clusters -o wide 2>/dev/null || true
  echo
  echo "gateway node annotations on ${context}:"
  log_command kubectl --context "${context}" get node "${context}" -o 'jsonpath={.metadata.annotations}'
  kc "${context}" get node "${context}" -o jsonpath='{.metadata.annotations}' 2>/dev/null || true
  echo
  echo "submariner gateway/route-agent logs on ${context}:"
  for pod in $(kc "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" get pods --no-headers 2>/dev/null | awk '$1 ~ /^submariner-(gateway|routeagent|route-agent)-/ {print $1}'); do
    echo "logs for ${context}/${pod}:"
    kc_logged "${context}" -n "${SUBMARINER_OPERATOR_NAMESPACE}" logs "${pod}" --all-containers --tail=160 || true
    echo
  done
}

if ! wait_for_connections "${SOURCE_CLUSTER_PROFILE}"; then
  dump_connection_diagnostics "${SOURCE_CLUSTER_PROFILE}"
  dump_connection_diagnostics "${RECOVERY_CLUSTER_PROFILE}"
  exit 1
fi

if ! wait_for_connections "${RECOVERY_CLUSTER_PROFILE}"; then
  dump_connection_diagnostics "${SOURCE_CLUSTER_PROFILE}"
  dump_connection_diagnostics "${RECOVERY_CLUSTER_PROFILE}"
  exit 1
fi
