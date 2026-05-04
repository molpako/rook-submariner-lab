#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd subctl
require_common_tools

require_mcs_crds() {
  local context="$1"
  local missing=0

  log "check MCS API resources on ${context}"
  for resource in serviceexports.multicluster.x-k8s.io serviceimports.multicluster.x-k8s.io; do
    if ! kc "${context}" get crd "${resource}" >/dev/null 2>&1; then
      echo "missing MCS API resource on ${context}: ${resource}" >&2
      missing=1
    fi
  done

  if (( missing == 0 )); then
    return 0
  fi

  echo
  echo "multicluster CRDs on ${context}:"
  kc "${context}" get crd 2>/dev/null | grep -E 'multicluster|service(export|import)' || true
  echo
  echo "lighthouse/submariner pods on ${context}:"
  kc "${context}" get pods -A 2>/dev/null | grep -E 'submariner|lighthouse' || true
  return 1
}

wait_for_service_import() {
  local context="$1"
  local provider_context="$2"
  local attempt=1
  local max_retries="${GLOBALNET_TEST_WAIT_RETRIES:-60}"
  local sleep_seconds="${GLOBALNET_TEST_WAIT_SECONDS:-5}"
  local imports

  while (( attempt <= max_retries )); do
    imports="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimports -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    if grep -qx "${GLOBALNET_TEST_SERVICE}" <<<"${imports}"; then
      log "ServiceImport/${GLOBALNET_TEST_SERVICE} detected on ${context}"
      return 0
    fi

    log "ServiceImport/${GLOBALNET_TEST_SERVICE} not detected on ${context} yet (${attempt}/${max_retries}), retrying"
    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "timed out waiting for ServiceImport/${GLOBALNET_TEST_SERVICE} on ${context}" >&2
  echo
  echo "service exports on ${provider_context}:"
  kc_logged "${provider_context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexports -o yaml || true
  echo
  echo "service imports on ${context}:"
  kc_logged "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimports -o yaml || true
  echo
  echo "lighthouse agent logs on ${provider_context}:"
  kc_logged "${provider_context}" -n submariner-operator logs -l app=submariner-lighthouse-agent --tail=160 || true
  echo
  echo "lighthouse agent logs on ${context}:"
  kc_logged "${context}" -n submariner-operator logs -l app=submariner-lighthouse-agent --tail=160 || true
  return 1
}

check_submariner_tunnel() {
  local local_context="$1"
  local expected_peer="$2"
  local attempt=1
  local max_retries="${GLOBALNET_TEST_CONNECTION_WAIT_RETRIES:-20}"
  local sleep_seconds="${GLOBALNET_TEST_CONNECTION_WAIT_SECONDS:-5}"
  local connections
  local peer_line

  while (( attempt <= max_retries )); do
    connections="$(subctl show connections --context "${local_context}" 2>&1 || true)"
    peer_line="$(grep -E "^[[:space:]]*${expected_peer}[[:space:]]|[[:space:]]${expected_peer}[[:space:]]" <<<"${connections}" || true)"

    if [[ -n "${peer_line}" ]] && echo "${peer_line}" | grep -Ei -q '[[:space:]](established|connected|up)[[:space:]]'; then
      log "Submariner tunnel established on ${local_context}: ${expected_peer}"
      return 0
    fi

    if [[ -z "${peer_line}" ]]; then
      if grep -Fq "No connections found" <<<"${connections}"; then
        log "No connections found on ${local_context} yet (${attempt}/${max_retries})"
      else
        log "subctl show connections on ${local_context} (waiting for ${expected_peer}):"
        log "${connections}"
      fi
    else
      log "Submariner peer ${expected_peer} found on ${local_context} but not established yet (${attempt}/${max_retries}):"
      log "${peer_line}"
    fi

    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "timed out waiting for Submariner tunnel to ${expected_peer} on ${local_context}" >&2
  echo "subctl show connections on ${local_context}:"
  subctl_logged show connections --context "${local_context}" || true
  echo
  echo "subctl show endpoints on ${local_context}:"
  subctl_logged show endpoints --context "${local_context}" || true
  echo
  echo "subctl show gateways on ${local_context}:"
  subctl_logged show gateways --context "${local_context}" || true
  echo
  dump_lighthouse_dns_state "${local_context}"
  return 1
}

service_import_ip() {
  local context="$1"
  local ip

  ip="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimport "${GLOBALNET_TEST_SERVICE}" \
    -o jsonpath='{.spec.ips[0]}' 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimport "${GLOBALNET_TEST_SERVICE}" \
      -o jsonpath='{.status.ips[0]}' 2>/dev/null || true)"
  fi
  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  ip="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimport "${GLOBALNET_TEST_SERVICE}" -o yaml 2>/dev/null \
    | grep -Eo '(10|11)\.[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1 || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  ip="$(kc "${BROKER_CONTEXT}" get serviceimports -A -o yaml 2>/dev/null \
    | grep -Eo '(10|11)\.[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1 || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi

  return 1
}

dump_lighthouse_dns_state() {
  local context="$1"

  echo
  echo "lighthouse/CoreDNS state on ${context}:"
  log_command_text "kubectl --context ${context} -n submariner-operator get svc,pods -o wide | grep -E 'lighthouse|coredns'"
  kc "${context}" -n submariner-operator get svc,pods -o wide | grep -E 'lighthouse|coredns' || true
  echo
  echo "kube-system coredns config on ${context}:"
  kc_logged "${context}" -n kube-system get configmap coredns -o yaml || true
}

wait_for_service_export_condition() {
  local context="$1"
  local condition="$2"
  local attempt=1
  local max_retries="${GLOBALNET_TEST_WAIT_RETRIES:-60}"
  local sleep_seconds="${GLOBALNET_TEST_WAIT_SECONDS:-5}"
  local status
  local reason
  local message

  while (( attempt <= max_retries )); do
    status="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexport "${GLOBALNET_TEST_SERVICE}" \
      -o "jsonpath={.status.conditions[?(@.type==\"${condition}\")].status}" 2>/dev/null || true)"
    reason="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexport "${GLOBALNET_TEST_SERVICE}" \
      -o "jsonpath={.status.conditions[?(@.type==\"${condition}\")].reason}" 2>/dev/null || true)"
    message="$(kc "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexport "${GLOBALNET_TEST_SERVICE}" \
      -o "jsonpath={.status.conditions[?(@.type==\"${condition}\")].message}" 2>/dev/null || true)"

    if [[ "${status}" == "True" ]]; then
      log "ServiceExport/${GLOBALNET_TEST_SERVICE} condition ${condition}=True on ${context}"
      return 0
    fi

    log "ServiceExport/${GLOBALNET_TEST_SERVICE} condition ${condition}=${status:-<unset>} reason=${reason:-<unset>} (${attempt}/${max_retries})"
    if [[ -n "${message}" ]]; then
      log "ServiceExport/${GLOBALNET_TEST_SERVICE} ${condition} message: ${message}"
    fi
    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "timed out waiting for ServiceExport/${GLOBALNET_TEST_SERVICE} condition ${condition}=True on ${context}" >&2
  echo
  echo "service export status:"
  kc_logged "${context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexport "${GLOBALNET_TEST_SERVICE}" -o yaml || true
  echo
  echo "broker service imports/exports:"
  kc_logged "${BROKER_CONTEXT}" get serviceexports,serviceimports -A -o wide || true
  echo
  echo "lighthouse agent logs on ${context}:"
  kc_logged "${context}" -n submariner-operator logs -l app=submariner-lighthouse-agent --tail=200 || true
  echo
  echo "lighthouse agent logs on ${BROKER_CONTEXT}:"
  kc_logged "${BROKER_CONTEXT}" -n submariner-operator logs -l app=submariner-lighthouse-agent --tail=200 || true
  return 1
}

show_globalnet_resources() {
  local context="$1"

  log "globalnet/MCS resources on ${context}"
  log_command_text "kubectl --context ${context} api-resources -o name | grep -E 'global|serviceexports|serviceimports'"
  kc "${context}" api-resources -o name | grep -E 'global|serviceexports|serviceimports' || true
  kc_logged "${context}" get serviceexports -A -o wide || true
  kc_logged "${context}" get serviceimports -A -o wide || true

  for resource in globalingressips globalegressips clusterglobalegressips; do
    if kc "${context}" api-resources -o name 2>/dev/null | grep -qx "${resource}"; then
      kc_logged "${context}" get "${resource}" -A -o wide || true
    fi
  done

  log_command_text "kubectl --context ${context} get svc -A -o wide | grep -E '10\\.|11\\.'"
  kc "${context}" get svc -A -o wide | grep -E '10\.|11\.' || true
}

run_client_probe() {
  local provider_context="$1"
  local client_context="$2"
  local fqdn="${GLOBALNET_TEST_SERVICE}.${GLOBALNET_TEST_NAMESPACE}.svc.clusterset.local"
  local global_ip
  local attempt=1
  local max_retries="${GLOBALNET_TEST_DNS_WAIT_RETRIES:-36}"
  local retry_sleep="${GLOBALNET_TEST_DNS_WAIT_SECONDS:-5}"
  local probe_ok=0

  log "create probe pod on ${client_context}"
  kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" delete pod "${GLOBALNET_TEST_CLIENT}" --ignore-not-found=true
  kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" run "${GLOBALNET_TEST_CLIENT}" \
    --image="${BUSYBOX_IMAGE}" \
    --restart=Never \
    --command -- sleep 3600
  kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" wait \
    --for=condition=Ready "pod/${GLOBALNET_TEST_CLIENT}" --timeout=180s

  global_ip="$(service_import_ip "${client_context}" || true)"
  if [[ -z "${global_ip}" ]]; then
    echo "failed to determine Globalnet ServiceImport IP for ${GLOBALNET_TEST_SERVICE}" >&2
    echo
    echo "ServiceImport on ${client_context}:"
    kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceimport "${GLOBALNET_TEST_SERVICE}" -o yaml || true
    echo
    echo "ServiceImports in all namespaces on ${client_context}:"
    kc_logged "${client_context}" get serviceimports -A -o yaml || true
    echo
    echo "ServiceImports in all namespaces on ${BROKER_CONTEXT}:"
    kc_logged "${BROKER_CONTEXT}" get serviceimports -A -o yaml || true
    return 1
  fi

  log "curl exported service through Globalnet IP ${global_ip} from ${client_context}"
  while (( attempt <= max_retries )); do
    if kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" exec "${GLOBALNET_TEST_CLIENT}" -- \
      wget -qO- --timeout=10 "http://${global_ip}"; then
      probe_ok=1
      break
    fi
    log "Global IP probe failed on ${client_context} (${attempt}/${max_retries})"
    sleep "${retry_sleep}"
    ((attempt += 1))
  done

  if (( probe_ok == 0 )); then
    echo "failed to connect to Globalnet IP ${global_ip} from ${client_context}" >&2
    dump_lighthouse_dns_state "${client_context}"
    return 1
  fi
  printf '\n'

  log "curl exported service through clusterset DNS from ${client_context}"
  attempt=1
  while (( attempt <= max_retries )); do
    if kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" exec "${GLOBALNET_TEST_CLIENT}" -- \
      wget -qO- --timeout=10 "http://${fqdn}"; then
      probe_ok=1
      break
    fi
    log "clusterset DNS HTTP probe failed on ${client_context} (${attempt}/${max_retries})"
    sleep "${retry_sleep}"
    ((attempt += 1))
  done

  if (( probe_ok == 0 )); then
    echo "failed to connect to clusterset DNS name ${fqdn} from ${client_context}" >&2
    dump_lighthouse_dns_state "${client_context}"
    dump_lighthouse_dns_state "${provider_context}"
    return 1
  fi
  printf '\n'

  log "best-effort DNS diagnostic for ${fqdn} from ${client_context}"
  kc_logged "${client_context}" -n "${GLOBALNET_TEST_NAMESPACE}" exec "${GLOBALNET_TEST_CLIENT}" -- nslookup "${fqdn}" || true
}

provider_context="${GLOBALNET_SOURCE_CONTEXT}"
client_context="${GLOBALNET_RECOVERY_CONTEXT}"

require_mcs_crds "${provider_context}"
require_mcs_crds "${client_context}"

log "Globalnet test direction: provider=${provider_context}, client=${client_context}"
log "deploy Globalnet test service on provider/source cluster ${provider_context}"
ensure_namespace "${client_context}" "${GLOBALNET_TEST_NAMESPACE}"
apply_manifest "${provider_context}" "${MANIFEST_DIR}/app/globalnet-test.yaml"
kc_logged "${provider_context}" -n "${GLOBALNET_TEST_NAMESPACE}" rollout status "deployment/${GLOBALNET_TEST_APP}" --timeout=180s

log "export ${GLOBALNET_TEST_NAMESPACE}/${GLOBALNET_TEST_SERVICE} from ${provider_context}"
if ! kc "${provider_context}" -n "${GLOBALNET_TEST_NAMESPACE}" get serviceexport "${GLOBALNET_TEST_SERVICE}" >/dev/null 2>&1; then
  subctl_logged export service \
    --context "${provider_context}" \
    --namespace "${GLOBALNET_TEST_NAMESPACE}" \
    "${GLOBALNET_TEST_SERVICE}"
fi

check_submariner_tunnel "${provider_context}" "${RECOVERY_CLUSTER_ID}"
check_submariner_tunnel "${client_context}" "${SOURCE_CLUSTER_ID}"

wait_for_service_export_condition "${provider_context}" Valid
wait_for_service_export_condition "${provider_context}" Ready

wait_for_service_import "${client_context}" "${provider_context}"

show_globalnet_resources "${provider_context}"
show_globalnet_resources "${client_context}"

run_client_probe "${provider_context}" "${client_context}"

log "Globalnet validation completed"
