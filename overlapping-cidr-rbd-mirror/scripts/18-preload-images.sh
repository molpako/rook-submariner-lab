#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_common_tools

CEPH_CSI_IMAGE="${CEPH_CSI_IMAGE:-quay.io/cephcsi/cephcsi:v3.16.2}"

groups=("$@")
if [[ "${#groups[@]}" -eq 0 ]]; then
  groups=(all)
fi

images=()
declare -A seen_images=()

add_image() {
  local image="$1"

  if [[ -z "${image}" ]]; then
    return
  fi

  if [[ -z "${seen_images[${image}]+x}" ]]; then
    images+=("${image}")
    seen_images["${image}"]=1
  fi
}

add_rook_images() {
  add_image "${ROOK_CEPH_OPERATOR_IMAGE}"
  add_image "${CEPH_CSI_OPERATOR_IMAGE}"
  add_image "${CEPH_CSI_IMAGE}"
  add_image "${CEPH_IMAGE}"
  add_image "registry.k8s.io/sig-storage/csi-attacher:v4.11.0"
  add_image "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.16.0"
  add_image "registry.k8s.io/sig-storage/csi-provisioner:v6.1.1"
  add_image "registry.k8s.io/sig-storage/csi-resizer:v2.1.0"
  add_image "registry.k8s.io/sig-storage/csi-snapshotter:v8.5.0"
}

resolve_submariner_image_tag() {
  local version="${SUBCTL_VERSION:-latest}"

  if [[ "${version}" == "latest" ]]; then
    if command -v subctl >/dev/null 2>&1; then
      version="$(subctl version 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | head -n1)"
    else
      version=""
    fi
  else
    version="${version#v}"
  fi

  echo "${version}"
}

add_submariner_images() {
  local tag
  tag="$(resolve_submariner_image_tag)"

  if [[ -z "${tag}" ]]; then
    log "skip submariner image preload: failed to resolve image tag from SUBCTL_VERSION=${SUBCTL_VERSION}"
    return
  fi

  add_image "quay.io/submariner/lighthouse-agent:${tag}"
  add_image "quay.io/submariner/lighthouse-coredns:${tag}"
  add_image "quay.io/submariner/nettest:${tag}"
  add_image "quay.io/submariner/submariner-gateway:${tag}"
  add_image "quay.io/submariner/submariner-globalnet:${tag}"
  add_image "quay.io/submariner/submariner-operator:${tag}"
  add_image "quay.io/submariner/submariner-route-agent:${tag}"
}

add_app_images() {
  add_image "${BUSYBOX_IMAGE}"
  add_image "registry.k8s.io/e2e-test-images/agnhost:2.53"
  add_image "registry.k8s.io/e2e-test-images/busybox:1.29-4"
}

for group in "${groups[@]}"; do
  case "${group}" in
    all)
      add_rook_images
      add_submariner_images
      add_app_images
      ;;
    rook)
      add_rook_images
      ;;
    submariner)
      add_submariner_images
      ;;
    app)
      add_app_images
      ;;
    *)
      echo "unknown preload image group: ${group}" >&2
      echo "valid groups: all rook submariner app" >&2
      exit 1
      ;;
  esac
done

profile_ready() {
  local profile="$1"
  kubectl --context "${profile}" get nodes --request-timeout=5s >/dev/null 2>&1
}

host_image_present() {
  local image="$1"
  docker image inspect "${image}" >/dev/null 2>&1
}

profile_image_present() {
  local profile="$1"
  local image="$2"

  minikube_cmd -p "${profile}" image ls --format=short | grep -Fxq "${image}"
}

ensure_profile_image_access() {
  local profile="$1"
  local images

  if ! minikube_cmd -p "${profile}" ssh -- true >/dev/null; then
    echo "minikube ssh is not available for ${profile}; image load cannot be trusted." >&2
    echo "If minikube start was interrupted, run 'make clean-clusters && make clusters' before preloading images." >&2
    return 1
  fi

  if ! images="$(minikube_cmd -p "${profile}" image ls --format=short)"; then
    echo "minikube image list failed for ${profile}." >&2
    echo "If minikube start was interrupted, run 'make clean-clusters && make clusters' before preloading images." >&2
    return 1
  fi

  if [[ -n "${images}" ]]; then
    return 0
  fi

  echo "minikube image list is empty for ${profile}; image load cannot be trusted." >&2
  echo "If minikube start was interrupted, run 'make clean-clusters && make clusters' before preloading images." >&2
  return 1
}

all_profiles_have_image() {
  local image="$1"

  profile_image_present "${SOURCE_CLUSTER_PROFILE}" "${image}" \
    && profile_image_present "${RECOVERY_CLUSTER_PROFILE}" "${image}"
}

pull_host_image() {
  local image="$1"
  local attempt

  if host_image_present "${image}"; then
    log "host image already present: ${image}"
    return 0
  fi

  for attempt in 1 2 3; do
    log "pull host image: ${image} (${attempt}/3)"
    if docker pull "${image}"; then
      return 0
    fi
    sleep 5
  done

  echo "failed to pull host image after retries: ${image}" >&2
  return 1
}

load_profile_image() {
  local profile="$1"
  local image="$2"

  if profile_image_present "${profile}" "${image}"; then
    log "minikube image already present on ${profile}: ${image}"
    return 0
  fi

  log "load image into ${profile}: ${image}"
  minikube_cmd -p "${profile}" image load --daemon=true --overwrite=false "${image}"
}

if ! profile_ready "${SOURCE_CLUSTER_PROFILE}" || ! profile_ready "${RECOVERY_CLUSTER_PROFILE}"; then
  echo "minikube profiles are not ready. Run 'make clusters' before preloading images." >&2
  exit 1
fi

ensure_profile_image_access "${SOURCE_CLUSTER_PROFILE}"
ensure_profile_image_access "${RECOVERY_CLUSTER_PROFILE}"

log "preload image groups: ${groups[*]}"
for image in "${images[@]}"; do
  if all_profiles_have_image "${image}"; then
    log "minikube image already present on both profiles: ${image}"
    continue
  fi

  pull_host_image "${image}"
  load_profile_image "${SOURCE_CLUSTER_PROFILE}" "${image}"
  load_profile_image "${RECOVERY_CLUSTER_PROFILE}" "${image}"
done

log "image preload complete: ${#images[@]} image(s)"
