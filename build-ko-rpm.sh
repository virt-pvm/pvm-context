#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-}

if [[ -z "$CONFIG" ]]; then
  echo "usage: $0 <target-config.sh>" >&2
  exit 2
fi
if [[ "$CONFIG" != /* ]]; then
  CONFIG="$PWD/$CONFIG"
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "target config not found: $CONFIG" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG"
LOCAL_CONFIG=${PVM_LOCAL_CONFIG:-"$ROOT_DIR/configs/targets.local.env"}
if [[ -f "$LOCAL_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$LOCAL_CONFIG"
fi
if ! declare -F pvm_vm_exec >/dev/null; then
  echo "target config must define pvm_vm_exec()" >&2
  exit 2
fi

: "${PVM_TARGET_NAME:=$(basename -- "$(dirname -- "$CONFIG")")}"
: "${PVM_KERNEL_RELEASE:=auto}"
: "${PVM_SOURCE_DIR:?PVM_SOURCE_DIR is required}"
: "${PVM_BASE_NAME:=unknown}"
: "${PVM_BASE_COMMIT:=unknown}"
: "${PVM_MODULE_SUBDIR:=arch/x86/kvm}"
: "${PVM_REQUIRED_MODULES:=kvm.ko kvm-pvm.ko kvm-amd.ko kvm-intel.ko}"
: "${PVM_LOAD_MODULE:=kvm_pvm}"
: "${PVM_LOADED_MODULE:=kvm_pvm}"
: "${PVM_MODULE_FILE:=kvm-pvm.ko}"
: "${PVM_ARTIFACT_DIR:=/tmp/pvm-oot-rpms}"
: "${PVM_JOBS:=8}"
: "${PVM_PREPARE_COMMAND:=true}"
: "${PVM_CC:=gcc}"
: "${PVM_RESOLVE_BTFIDS:=}"
: "${PVM_CLEAN_COMMAND:=}"
: "${PVM_BUILD_COMMAND:=}"
: "${PVM_INSTALL_COMMAND:=}"
: "${PVM_POST_TEST_COMMAND:=true}"
: "${PVM_POST_TEST_TIMEOUT:=900}"

encode() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

remote_env=$(printf \
  'PVM_TARGET_NAME_B64=%q PVM_KERNEL_RELEASE_B64=%q PVM_SOURCE_DIR_B64=%q PVM_BASE_NAME_B64=%q PVM_BASE_COMMIT_B64=%q PVM_MODULE_SUBDIR_B64=%q PVM_REQUIRED_MODULES_B64=%q PVM_LOAD_MODULE_B64=%q PVM_LOADED_MODULE_B64=%q PVM_MODULE_FILE_B64=%q PVM_ARTIFACT_DIR_B64=%q PVM_JOBS_B64=%q PVM_PREPARE_COMMAND_B64=%q PVM_CC_B64=%q PVM_RESOLVE_BTFIDS_B64=%q PVM_CLEAN_COMMAND_B64=%q PVM_BUILD_COMMAND_B64=%q PVM_INSTALL_COMMAND_B64=%q PVM_POST_TEST_COMMAND_B64=%q PVM_POST_TEST_TIMEOUT_B64=%q' \
  "$(encode "$PVM_TARGET_NAME")" \
  "$(encode "$PVM_KERNEL_RELEASE")" \
  "$(encode "$PVM_SOURCE_DIR")" \
  "$(encode "$PVM_BASE_NAME")" \
  "$(encode "$PVM_BASE_COMMIT")" \
  "$(encode "$PVM_MODULE_SUBDIR")" \
  "$(encode "$PVM_REQUIRED_MODULES")" \
  "$(encode "$PVM_LOAD_MODULE")" \
  "$(encode "$PVM_LOADED_MODULE")" \
  "$(encode "$PVM_MODULE_FILE")" \
  "$(encode "$PVM_ARTIFACT_DIR")" \
  "$(encode "$PVM_JOBS")" \
  "$(encode "$PVM_PREPARE_COMMAND")" \
  "$(encode "$PVM_CC")" \
  "$(encode "$PVM_RESOLVE_BTFIDS")" \
  "$(encode "$PVM_CLEAN_COMMAND")" \
  "$(encode "$PVM_BUILD_COMMAND")" \
  "$(encode "$PVM_INSTALL_COMMAND")" \
  "$(encode "$PVM_POST_TEST_COMMAND")" \
  "$(encode "$PVM_POST_TEST_TIMEOUT")")

TARGET_DIR=$(dirname -- "$CONFIG")
LOG_FILE="$TARGET_DIR/build-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "target=$PVM_TARGET_NAME config=$CONFIG log=$LOG_FILE"
pvm_vm_exec "$remote_env bash -s" < "$ROOT_DIR/lib/guest-build-ko-rpm.sh" \
  2>&1 | tee "$LOG_FILE"
ln -sfn "$(basename -- "$LOG_FILE")" "$TARGET_DIR/last-build.log"
