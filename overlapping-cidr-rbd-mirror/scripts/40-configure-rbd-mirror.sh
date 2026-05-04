#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_common_tools

log "rbd mirror topology: source=${SOURCE_CLUSTER_PROFILE}, pull/mirror=${RECOVERY_CLUSTER_PROFILE}, broker=${BROKER_CONTEXT}"

bootstrap_secret_name() {
  local context="$1"
  wait_for_nonempty_jsonpath \
    "${context}" \
    "${ROOK_NAMESPACE}" \
    cephblockpool \
    "${MIRRORED_POOL_NAME}" \
    '{.status.info.rbdMirrorBootstrapPeerSecretName}'
}

peer_token() {
  local context="$1"
  local secret_name="$2"
  kc "${context}" -n "${ROOK_NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.token}' | base64 -d
}

create_peer_secret() {
  local context="$1"
  local secret_name="$2"
  local token="$3"
  local direction="${4:-}"

  kc_logged "${context}" -n "${ROOK_NAMESPACE}" delete secret "${secret_name}" --ignore-not-found
  local secret_args=(
    --from-literal=token="${token}"
    --from-literal=pool="${MIRRORED_POOL_NAME}"
  )
  if [[ -n "${direction}" ]]; then
    secret_args+=(--from-literal=direction="${direction}")
  fi

  log "create rbd mirror peer secret ${secret_name} on ${context} (token redacted)"
  log_command kubectl --context "${context}" -n "${ROOK_NAMESPACE}" create secret generic "${secret_name}" \
    --from-literal=token='<redacted>' \
    --from-literal=pool="${MIRRORED_POOL_NAME}" \
    ${direction:+--from-literal=direction="${direction}"}
  kc "${context}" -n "${ROOK_NAMESPACE}" create secret generic "${secret_name}" \
    "${secret_args[@]}"
}

patch_pool_peer() {
  local context="$1"
  local secret_name="$2"

  kc_logged "${context}" -n "${ROOK_NAMESPACE}" patch cephblockpool "${MIRRORED_POOL_NAME}" \
    --type merge \
    -p "{\"spec\":{\"mirroring\":{\"peers\":{\"secretNames\":[\"${secret_name}\"]}}}}"
}

peer_uuid() {
  local context="$1"

  rook_toolbox "${context}" rbd mirror pool info "${MIRRORED_POOL_NAME}" --format json \
    | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p'
}

set_peer_direction() {
  local context="$1"
  local direction="$2"
  local uuid=""

  for attempt in $(seq 1 24); do
    uuid="$(peer_uuid "${context}")"
    if [[ -n "${uuid}" ]]; then
      log "set ${context} mirrored pool peer ${uuid} direction=${direction}"
      rook_toolbox_logged "${context}" rbd mirror pool peer set "${MIRRORED_POOL_NAME}" "${uuid}" direction "${direction}"
      return 0
    fi

    log "mirrored pool peer not visible on ${context} yet (${attempt}/24), retrying"
    sleep 5
  done

  echo "timed out waiting for mirrored pool peer on ${context}" >&2
  kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o yaml || true
  return 1
}

wait_for_pool_peer_secret() {
  local context="$1"
  local secret_name="$2"

  if ! wait_for_jsonpath_value \
    "${context}" \
    "${ROOK_NAMESPACE}" \
    cephblockpool \
    "${MIRRORED_POOL_NAME}" \
    '{.spec.mirroring.peers.secretNames[0]}' \
    "${secret_name}" \
    "120" "5"; then
    echo "rbd mirror peer secret not reflected yet on ${context}: expected secretNames[0] to be ${secret_name}" >&2
    kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o yaml || true
    return 1
  fi
}

wait_for_pool_mirror_summary() {
  local context="$1"

  if ! wait_for_nonempty_jsonpath \
    "${context}" \
    "${ROOK_NAMESPACE}" \
    cephblockpool \
    "${MIRRORED_POOL_NAME}" \
    '{.status.mirroringStatus.summary}' \
    "120" "5"; then
    echo "mirroringStatus.summary is still empty on ${context}; pool status not ready for sync checks yet" >&2
    kc_logged "${context}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o yaml || true
    return 1
  fi
}

log "wait for source bootstrap peer secret on ${SOURCE_CLUSTER_PROFILE}"
source_bootstrap_secret="$(bootstrap_secret_name "${SOURCE_CLUSTER_PROFILE}")"
log "wait for recovery bootstrap peer secret on ${RECOVERY_CLUSTER_PROFILE}"
recovery_bootstrap_secret="$(bootstrap_secret_name "${RECOVERY_CLUSTER_PROFILE}")"

log "configure source tx peer on ${SOURCE_CLUSTER_PROFILE}"
recovery_to_source_secret="rbd-peer-from-${RECOVERY_CLUSTER_ID}"
recovery_token="$(peer_token "${RECOVERY_CLUSTER_PROFILE}" "${recovery_bootstrap_secret}")"
create_peer_secret "${SOURCE_CLUSTER_PROFILE}" "${recovery_to_source_secret}" "${recovery_token}" "rx-tx"
patch_pool_peer "${SOURCE_CLUSTER_PROFILE}" "${recovery_to_source_secret}"

log "configure recovery rx peer on ${RECOVERY_CLUSTER_PROFILE}"
source_to_recovery_secret="rbd-peer-from-${SOURCE_CLUSTER_ID}"
source_token="$(peer_token "${SOURCE_CLUSTER_PROFILE}" "${source_bootstrap_secret}")"
create_peer_secret "${RECOVERY_CLUSTER_PROFILE}" "${source_to_recovery_secret}" "${source_token}" "rx-only"
patch_pool_peer "${RECOVERY_CLUSTER_PROFILE}" "${source_to_recovery_secret}"

log "wait for mirrored pool peer config on ${SOURCE_CLUSTER_PROFILE}"
wait_for_pool_peer_secret "${SOURCE_CLUSTER_PROFILE}" "${recovery_to_source_secret}"
log "wait for mirrored pool peer config on ${RECOVERY_CLUSTER_PROFILE}"
wait_for_pool_peer_secret "${RECOVERY_CLUSTER_PROFILE}" "${source_to_recovery_secret}"

log "wait for mirrored pool mirroring summary on ${SOURCE_CLUSTER_PROFILE}"
wait_for_pool_mirror_summary "${SOURCE_CLUSTER_PROFILE}"
log "wait for mirrored pool mirroring summary on ${RECOVERY_CLUSTER_PROFILE}"
wait_for_pool_mirror_summary "${RECOVERY_CLUSTER_PROFILE}"

set_peer_direction "${SOURCE_CLUSTER_PROFILE}" "tx-only"
set_peer_direction "${RECOVERY_CLUSTER_PROFILE}" "rx-only"

log "rbd mirror pull peer configured: source=${SOURCE_CLUSTER_PROFILE}, pull/mirror=${RECOVERY_CLUSTER_PROFILE}"
