#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl

sync_profile_kubeconfig "${SOURCE_CLUSTER_PROFILE}"
sync_profile_kubeconfig "${RECOVERY_CLUSTER_PROFILE}"

kubectl config get-contexts "${SOURCE_CLUSTER_PROFILE}" "${RECOVERY_CLUSTER_PROFILE}" || true
