#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_common_tools

sample_pv_name() {
  kc "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o jsonpath='{.spec.volumeName}'
}

sample_rbd_image_name() {
  local pv_name="$1"
  kc "${SOURCE_CLUSTER_PROFILE}" get pv "${pv_name}" -o jsonpath='{.spec.csi.volumeAttributes.imageName}'
}

sample_rbd_pool_name() {
  local pv_name="$1"
  local pool

  pool="$(kc "${SOURCE_CLUSTER_PROFILE}" get pv "${pv_name}" -o jsonpath='{.spec.csi.volumeAttributes.pool}' 2>/dev/null || true)"
  if [[ -z "${pool}" ]]; then
    pool="${MIRRORED_POOL_NAME}"
  fi
  printf '%s' "${pool}"
}

enable_sample_snapshot_mirroring() {
  local pv_name
  local image_name
  local pool_name
  local image_spec

  pv_name="$(sample_pv_name)"
  image_name="$(sample_rbd_image_name "${pv_name}")"
  pool_name="$(sample_rbd_pool_name "${pv_name}")"

  if [[ -z "${image_name}" || -z "${pool_name}" ]]; then
    echo "failed to determine sample RBD image from pvc ${TEST_NAMESPACE}/${TEST_PVC_NAME}; pv=${pv_name:-empty} pool=${pool_name:-empty} image=${image_name:-empty}" >&2
    kc_logged "${SOURCE_CLUSTER_PROFILE}" get pv "${pv_name}" -o yaml >&2 || true
    return 1
  fi

  image_spec="${pool_name}/${image_name}"
  log "enable snapshot-based rbd mirroring for ${image_spec} on source cluster ${SOURCE_CLUSTER_PROFILE}"
  log_command kubectl --context "${SOURCE_CLUSTER_PROFILE}" -n "${ROOK_NAMESPACE}" exec deploy/rook-ceph-tools -- rbd mirror image status "${image_spec}"
  if rook_toolbox "${SOURCE_CLUSTER_PROFILE}" rbd mirror image status "${image_spec}" >/dev/null 2>&1; then
    log "rbd image mirroring is already enabled for ${image_spec}"
  else
    rook_toolbox_logged "${SOURCE_CLUSTER_PROFILE}" rbd mirror image enable "${image_spec}" snapshot
  fi

  log "create initial mirror snapshot for ${image_spec} on source cluster ${SOURCE_CLUSTER_PROFILE}"
  rook_toolbox_logged "${SOURCE_CLUSTER_PROFILE}" rbd mirror image snapshot "${image_spec}"

  log "sample rbd mirror image status on ${SOURCE_CLUSTER_PROFILE}"
  rook_toolbox_logged "${SOURCE_CLUSTER_PROFILE}" rbd mirror image status "${image_spec}" || true
}

wait_for_sample_deleted() {
  local attempt

  for attempt in $(seq 1 120); do
    if ! kc "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" get pod "${TEST_POD_NAME}" >/dev/null 2>&1 \
      && ! kc "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" >/dev/null 2>&1; then
      return 0
    fi

    log "sample pod/pvc still deleting on ${SOURCE_CLUSTER_PROFILE} (${attempt}/120), retrying"
    sleep 5
  done

  echo "timed out waiting for old sample pod/pvc deletion on ${SOURCE_CLUSTER_PROFILE}" >&2
  dump_sample_diagnostics "${SOURCE_CLUSTER_PROFILE}"
  return 1
}

log "deploy sample pvc and writer pod on source cluster ${SOURCE_CLUSTER_PROFILE}"
kc_logged "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" delete pod "${TEST_POD_NAME}" --ignore-not-found
kc_logged "${SOURCE_CLUSTER_PROFILE}" -n "${TEST_NAMESPACE}" delete pvc "${TEST_PVC_NAME}" --ignore-not-found
wait_for_sample_deleted
apply_manifest "${SOURCE_CLUSTER_PROFILE}" "${MANIFEST_DIR}/app/test-namespace.yaml"
apply_manifest "${SOURCE_CLUSTER_PROFILE}" "${MANIFEST_DIR}/app/test-pvc.yaml"
apply_manifest "${SOURCE_CLUSTER_PROFILE}" "${MANIFEST_DIR}/app/writer-pod.yaml"

log "wait for sample pvc ${TEST_NAMESPACE}/${TEST_PVC_NAME} on ${SOURCE_CLUSTER_PROFILE}"
if ! wait_for_pvc_bound "${SOURCE_CLUSTER_PROFILE}" "${TEST_NAMESPACE}" "${TEST_PVC_NAME}" "600s"; then
  echo "sample PVC did not become Bound on ${SOURCE_CLUSTER_PROFILE}" >&2
  dump_sample_diagnostics "${SOURCE_CLUSTER_PROFILE}"
  exit 1
fi

log "wait for sample writer pod ${TEST_NAMESPACE}/${TEST_POD_NAME} on ${SOURCE_CLUSTER_PROFILE}"
if ! wait_for_pod_label "${SOURCE_CLUSTER_PROFILE}" "${TEST_NAMESPACE}" "app=${TEST_POD_NAME}" "600s"; then
  echo "sample writer pod did not become Ready on ${SOURCE_CLUSTER_PROFILE}" >&2
  dump_sample_diagnostics "${SOURCE_CLUSTER_PROFILE}"
  exit 1
fi

enable_sample_snapshot_mirroring

log "sample workload deployed"
