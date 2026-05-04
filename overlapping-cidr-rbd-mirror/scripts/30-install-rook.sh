#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl
require_common_tools

delete_namespace_if_present() {
  local context="$1"
  local namespace="$2"

  if kc "${context}" get namespace "${namespace}" >/dev/null 2>&1; then
    log "delete existing namespace ${namespace} on ${context}"
    kc "${context}" delete namespace "${namespace}" --ignore-not-found --wait=false
  fi
}

clear_rook_finalizers() {
  local context="$1"

  kc "${context}" -n "${ROOK_NAMESPACE}" patch cephcluster "${ROOK_CLUSTER_NAME}" \
    --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kc "${context}" -n "${ROOK_NAMESPACE}" patch cephblockpool "${MIRRORED_POOL_NAME}" \
    --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kc "${context}" -n "${ROOK_NAMESPACE}" patch cephrbdmirror "${RBD_MIRROR_NAME}" \
    --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kc "${context}" -n "${ROOK_NAMESPACE}" patch configmap rook-ceph-mon-endpoints \
    --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kc "${context}" -n "${ROOK_NAMESPACE}" patch secret rook-ceph-mon \
    --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  while IFS= read -r resource; do
    [[ -z "${resource}" ]] && continue
    kc "${context}" -n "${ROOK_NAMESPACE}" patch "${resource}" \
      --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done < <(kc "${context}" -n "${ROOK_NAMESPACE}" get clientprofiles.csi.ceph.io -o name 2>/dev/null || true)
}

wait_for_namespace_deleted() {
  local context="$1"
  local namespace="$2"
  local attempt

  for attempt in $(seq 1 120); do
    if ! kc "${context}" get namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "${namespace}" == "${ROOK_NAMESPACE}" ]]; then
      clear_rook_finalizers "${context}"
    elif [[ "${namespace}" == "${TEST_NAMESPACE}" ]]; then
      clear_sample_finalizers "${context}"
      delete_sample_volumeattachments "${context}"
    fi
    log "namespace ${namespace} still terminating on ${context} (${attempt}/120), retrying"
    sleep 5
  done

  echo "timed out waiting for namespace ${namespace} deletion on ${context}" >&2
  kc_logged "${context}" get namespace "${namespace}" -o yaml >&2 || true
  return 1
}

delete_sample_volumeattachments() {
  local context="$1"
  local pv_names
  local pv_name

  pv_names="$(kc "${context}" -n "${TEST_NAMESPACE}" get pvc \
    -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "${pv_names}" ]]; then
    return 0
  fi

  while IFS= read -r pv_name; do
    [[ -z "${pv_name}" ]] && continue
    while IFS= read -r attachment; do
      [[ -z "${attachment}" ]] && continue
      log "delete stale VolumeAttachment ${attachment} for ${pv_name} on ${context}"
      kc_logged "${context}" delete volumeattachment "${attachment}" --ignore-not-found --wait=false
    done < <(
      kc "${context}" get volumeattachments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.source.persistentVolumeName}{"\n"}{end}' 2>/dev/null \
        | awk -v pv="${pv_name}" '$2 == pv {print $1}' || true
    )
  done <<<"${pv_names}"
}

clear_sample_finalizers() {
  local context="$1"
  local pv_names
  local pv_name

  kc "${context}" -n "${TEST_NAMESPACE}" delete pod --all \
    --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true

  pv_names="$(kc "${context}" -n "${TEST_NAMESPACE}" get pvc \
    -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)"

  while IFS= read -r resource; do
    [[ -z "${resource}" ]] && continue
    kc "${context}" -n "${TEST_NAMESPACE}" patch "${resource}" \
      --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done < <(kc "${context}" -n "${TEST_NAMESPACE}" get pvc -o name 2>/dev/null || true)

  while IFS= read -r pv_name; do
    [[ -z "${pv_name}" ]] && continue
    kc "${context}" patch pv "${pv_name}" --type merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kc "${context}" delete pv "${pv_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done <<<"${pv_names}"
}

wipe_rook_node_state() {
  local context="$1"

  log "wipe rook host state and extra disks on ${context}"
  log_command minikube -p "${context}" ssh -- "sudo sh -euxc '<wipe rook host state and extra disks; ceph-volume zap output follows>'"
  minikube_cmd -p "${context}" ssh -- "sudo sh -euxc '
    rm -rf ${ROOK_DATA_DIR:?}/*
    for dev in /dev/vdb /dev/vdc /dev/vdd /dev/sdb /dev/sdc /dev/sdd; do
      [ -b \"\$dev\" ] || continue
      swapoff \"\$dev\" 2>/dev/null || true
      if command -v docker >/dev/null 2>&1 && docker image inspect ${CEPH_IMAGE} >/dev/null 2>&1; then
        docker run --rm --privileged --net=host --pid=host -v /dev:/dev ${CEPH_IMAGE} \
          ceph-volume lvm zap --destroy \"\$dev\" || true
      fi
      blkdiscard -f \"\$dev\" 2>/dev/null || true
      size=\$(blockdev --getsize64 \"\$dev\" 2>/dev/null || echo 0)
      dd if=/dev/zero of=\"\$dev\" bs=4M count=32 conv=fsync 2>/dev/null || true
      if [ \"\$size\" -gt 134217728 ]; then
        seek=\$(((size / 4194304) - 32))
        dd if=/dev/zero of=\"\$dev\" bs=4M count=32 seek=\"\$seek\" conv=fsync 2>/dev/null || true
      fi
    done
    udevadm settle 2>/dev/null || true
  '"
}

reset_rook_cluster_state() {
  local context="$1"

  delete_sample_volumeattachments "${context}"
  clear_sample_finalizers "${context}"
  clear_rook_finalizers "${context}"
  delete_namespace_if_present "${context}" "${TEST_NAMESPACE}"
  delete_namespace_if_present "${context}" "${ROOK_NAMESPACE}"
  wait_for_namespace_deleted "${context}" "${TEST_NAMESPACE}"
  wait_for_namespace_deleted "${context}" "${ROOK_NAMESPACE}"
  wipe_rook_node_state "${context}"
}

configure_lab_ceph_pools() {
  local context="$1"

  log "configure lab ceph pool sizing on ${context}"
  if ! wait_for_jsonpath_value "${context}" "${ROOK_NAMESPACE}" cephcluster "${ROOK_CLUSTER_NAME}" '{.status.phase}' "Ready" "120" "5"; then
    echo "CephCluster did not become Ready before lab pool sizing on ${context}" >&2
    dump_sample_diagnostics "${context}"
    return 1
  fi

  # The lab is a single Kubernetes node with multiple OSDs. Ceph's automatically
  # created .mgr pool defaults to size=3 on a host failure domain, which leaves
  # its PG inactive and blocks rbd-mirror's startup pool scan.
  rook_toolbox_logged "${context}" ceph osd pool set .mgr size 1 --yes-i-really-mean-it
  rook_toolbox_logged "${context}" ceph osd pool set .mgr min_size 1
}

deploy_cluster() {
  local context="$1"
  local cluster_id="$2"
  local node_name

  reset_rook_cluster_state "${context}"
  install_rook_operator "${context}"

  node_name="$(cluster_node_name "${context}")"
  log "apply ceph cluster manifest on ${context} using node ${node_name}"
  apply_manifest "${context}" "${MANIFEST_DIR}/rook/templates/ceph-cluster.yaml.tpl" "${cluster_id}" "${node_name}"

  log "wait for cephcluster object on ${context}"
  wait_for_nonempty_jsonpath "${context}" "${ROOK_NAMESPACE}" cephcluster "${ROOK_CLUSTER_NAME}" '{.status.phase}' >/dev/null
  if ! wait_for_jsonpath_value "${context}" "${ROOK_NAMESPACE}" cephcluster "${ROOK_CLUSTER_NAME}" '{.status.phase}' "Ready" "180" "5"; then
    echo "CephCluster did not become Ready on ${context}" >&2
    dump_sample_diagnostics "${context}"
    return 1
  fi

  log "apply mirrored pool and storage class on ${context}"
  if ! kc "${context}" get storageclass "${STORAGE_CLASS_NAME}" >/dev/null 2>&1; then
    apply_manifest "${context}" "${MANIFEST_DIR}/rook/common/storageclass.yaml"
  else
    kc "${context}" delete storageclass "${STORAGE_CLASS_NAME}" --ignore-not-found
    apply_manifest "${context}" "${MANIFEST_DIR}/rook/common/storageclass.yaml"
  fi
  apply_manifest "${context}" "${MANIFEST_DIR}/rook/common/ceph-block-pool.yaml"
  if ! wait_for_jsonpath_value "${context}" "${ROOK_NAMESPACE}" cephblockpool "${MIRRORED_POOL_NAME}" '{.status.phase}' "Ready" "120" "5"; then
    echo "CephBlockPool did not become Ready on ${context}" >&2
    dump_sample_diagnostics "${context}"
    return 1
  fi

  install_rook_toolbox "${context}"
  configure_lab_ceph_pools "${context}"
}

deploy_cluster "${SOURCE_CLUSTER_PROFILE}" "${SOURCE_CLUSTER_ID}"
deploy_cluster "${RECOVERY_CLUSTER_PROFILE}" "${RECOVERY_CLUSTER_ID}"

log "apply rbd mirror daemon on recovery cluster ${RECOVERY_CLUSTER_PROFILE}"
apply_manifest "${RECOVERY_CLUSTER_PROFILE}" "${MANIFEST_DIR}/rook/common/ceph-rbd-mirror.yaml"
wait_for_pod_name_prefix "${RECOVERY_CLUSTER_PROFILE}" "${ROOK_NAMESPACE}" "rook-ceph-rbd-mirror-" "180" "5"

log "rook installation manifests applied; rbd mirror daemon is only on ${RECOVERY_CLUSTER_PROFILE}"
