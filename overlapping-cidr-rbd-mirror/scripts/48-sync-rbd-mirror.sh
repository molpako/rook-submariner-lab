#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_common_tools

sync_secret_name="rbd-peer-from-${SOURCE_CLUSTER_ID}"

sample_image_info() {
  local pv_name
  local pool
  local image

  pv_name="$(kc "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  if [[ -z "${pv_name}" ]]; then
    return 1
  fi

  image="$(kc "${SOURCE_CLUSTER_PROFILE}" get pv "${pv_name}" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || true)"
  pool="$(kc "${SOURCE_CLUSTER_PROFILE}" get pv "${pv_name}" -o jsonpath='{.spec.csi.volumeAttributes.pool}' 2>/dev/null || true)"
  if [[ -z "${pool}" ]]; then
    pool="${MIRRORED_POOL_NAME}"
  fi

  if [[ -z "${image}" || -z "${pool}" ]]; then
    return 1
  fi

  printf '%s/%s\n' "${pool}" "${image}"
}

verify_sample_image_sync_if_present() {
  local image_spec
  local attempt=1
  local retries=120
  local sleep_seconds=5

  if ! image_spec="$(sample_image_info)"; then
    log "sample pvc ${TEST_NAMESPACE}/${TEST_PVC_NAME} is not present; skip image-level sync verification"
    return 0
  fi

  log "refresh source mirror snapshot for ${image_spec} on ${SOURCE_CLUSTER_PROFILE}"
  log_command kubectl --context "${SOURCE_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- rbd mirror image status "${image_spec}"
  if ! rook_toolbox "${SOURCE_CLUSTER_PROFILE}" rbd mirror image status "${image_spec}" >/dev/null 2>&1; then
    rook_toolbox_logged "${SOURCE_CLUSTER_PROFILE}" rbd mirror image enable "${image_spec}" snapshot
  fi
  rook_toolbox_logged "${SOURCE_CLUSTER_PROFILE}" rbd mirror image snapshot "${image_spec}"

  log "wait for mirrored image ${image_spec} on recovery cluster ${RECOVERY_CLUSTER_PROFILE}"
  while (( attempt <= retries )); do
    log_command kubectl --context "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- rbd info "${image_spec}"
    if rook_toolbox "${RECOVERY_CLUSTER_PROFILE}" rbd info "${image_spec}" >/dev/null 2>&1; then
      rook_toolbox_logged "${RECOVERY_CLUSTER_PROFILE}" rbd mirror image status "${image_spec}" || true
      return 0
    fi

    log "mirrored image ${image_spec} not visible on ${RECOVERY_CLUSTER_PROFILE} yet (${attempt}/${retries}), retrying"
    sleep "${sleep_seconds}"
    ((attempt += 1))
  done

  echo "timed out waiting for mirrored image ${image_spec} on ${RECOVERY_CLUSTER_PROFILE}" >&2
  echo "source image mirror status:" >&2
  log_command kubectl --context "${SOURCE_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- rbd mirror image status "${image_spec}" >&2
  rook_toolbox "${SOURCE_CLUSTER_PROFILE}" rbd mirror image status "${image_spec}" >&2 || true
  echo "recovery pool mirror status:" >&2
  log_command kubectl --context "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- rbd mirror pool status "${MIRRORED_POOL_NAME}" >&2
  rook_toolbox "${RECOVERY_CLUSTER_PROFILE}" rbd mirror pool status "${MIRRORED_POOL_NAME}" >&2 || true
  return 1
}

log "verify rbd mirror peer secret propagation and mirror readiness"
log "expected peer secret on ${RECOVERY_CLUSTER_PROFILE}: ${sync_secret_name}"

if ! wait_for_nonempty_jsonpath \
  "${SOURCE_CLUSTER_PROFILE}" \
  "${ROOK_NAMESPACE}" \
  cephblockpool \
  "${MIRRORED_POOL_NAME}" \
  '{.status.info.rbdMirrorBootstrapPeerSecretName}' \
  "180" "5"; then
  echo "source mirrored pool does not report bootstrap peer secret name yet on ${SOURCE_CLUSTER_PROFILE}" >&2
  kc_logged "${SOURCE_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o yaml || true
  exit 1
fi

if ! wait_for_pod_name_prefix "${RECOVERY_CLUSTER_PROFILE}" "${ROOK_NAMESPACE}" "rook-ceph-rbd-mirror-" "180" "5"; then
  echo "rbd mirror daemon pod is not ready on ${RECOVERY_CLUSTER_PROFILE}" >&2
  kc_logged "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" get pods || true
  exit 1
fi

if ! wait_for_jsonpath_value \
  "${RECOVERY_CLUSTER_PROFILE}" \
  "${ROOK_NAMESPACE}" \
  cephblockpool \
  "${MIRRORED_POOL_NAME}" \
  '{.spec.mirroring.peers.secretNames[0]}' \
  "${sync_secret_name}" \
  "120" \
  "5"; then
  echo "recovery pool on ${RECOVERY_CLUSTER_PROFILE} does not contain expected peer secret ${sync_secret_name}" >&2
  kc_logged "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o yaml || true
  exit 1
fi

if ! wait_for_nonempty_jsonpath \
  "${RECOVERY_CLUSTER_PROFILE}" \
  "${ROOK_NAMESPACE}" \
  cephblockpool \
  "${MIRRORED_POOL_NAME}" \
  '{.status.mirroringStatus.summary}' \
  "180" \
  "5"; then
  echo "mirroring status summary is still empty on ${RECOVERY_CLUSTER_PROFILE}; check rbdmirror logs" >&2
  kc_logged "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" logs -l app=rook-ceph-rbd-mirror --tail=200 || true
  exit 1
fi

log "rbd mirror sync state appears ready on ${RECOVERY_CLUSTER_PROFILE}"
log_command_text "kubectl --context ${RECOVERY_CLUSTER_PROFILE} -n ${ROOK_NAMESPACE} get cephblockpool ${MIRRORED_POOL_NAME} -o jsonpath='{.status.mirroringStatus.summary}' | sed 's/^/status summary: /'"
kc "${RECOVERY_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" get cephblockpool "${MIRRORED_POOL_NAME}" -o jsonpath='{.status.mirroringStatus.summary}' | sed 's/^/status summary: /' || true
echo

verify_sample_image_sync_if_present
