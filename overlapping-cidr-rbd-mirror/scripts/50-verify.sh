#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd subctl
require_common_tools

show_cluster_state() {
  local context="$1"

  log "submariner connections on ${context}"
  subctl_logged show connections --context "${context}"

  log "submariner gateways on ${context}"
  subctl_logged show gateways --context "${context}"

  log "service exports on ${context}"
  kc_logged "${context}" get serviceexports -A || true

  log "service imports on ${context}"
  kc_logged "${context}" get serviceimports -A || true

  log "rook resources on ${context}"
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephcluster
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool
  if [[ "${context}" == "${RECOVERY_CLUSTER_PROFILE}" ]]; then
    kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephrbdmirror
  else
    log "skip cephrbdmirror check on ${context}; rbd mirror daemon is deployed only on ${RECOVERY_CLUSTER_PROFILE}"
  fi
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get pods -o wide

  log "mirroring summary on ${context}"
  log_command kubectl --context "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" \
    -o 'jsonpath={.status.mirroringStatus.summary}'
  kc "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" \
    -o jsonpath='{.status.mirroringStatus.summary}'
  printf '\n'
}

show_cluster_state "${SOURCE_CLUSTER_PROFILE}"
show_cluster_state "${RECOVERY_CLUSTER_PROFILE}"

log "sample workload on ${SOURCE_CLUSTER_PROFILE}"
kc_logged "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" get pvc,pod
