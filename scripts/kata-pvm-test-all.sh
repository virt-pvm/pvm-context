#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNNER="${KATA_TEST_RUNNER:-$SCRIPT_DIR/kata-pvm-oci-test.sh}"
CONFIG_DIR="${KATA_CONFIG_DIR:-/etc/kata-containers/pvm}"
GUEST_KERNEL="${PVM_GUEST_KERNEL:-/opt/kata/share/kata-containers/vmlinux.pvm}"

declare -A CONFIGS=(
  [qemu]="$CONFIG_DIR/configuration-qemu-pvm.toml"
  [clh]="$CONFIG_DIR/configuration-clh-pvm.toml"
  [dragonball]="$CONFIG_DIR/configuration-dragonball-pvm.toml"
)
declare -A RUNTIMES=(
  [qemu]="io.containerd.kata.v2"
  [clh]="io.containerd.kata.v2"
  [dragonball]="io.containerd.kata.v2"
)

hypervisor_value() {
  local python=python3
  command -v python3.11 >/dev/null 2>&1 && python=python3.11
  "$python" - "$1" "$2" "$3" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    config = tomllib.load(source)
value = config.get("hypervisor", {}).get(sys.argv[2], {}).get(sys.argv[3], "")
print(value if isinstance(value, (str, int, float)) else "")
PY
}

preflight_hypervisor() {
  local hypervisor=$1 config=${CONFIGS[$1]} path machine firmware
  [[ -f "$config" ]] || { echo "Kata config not found: $config" >&2; return 1; }
  path=$(hypervisor_value "$config" "$hypervisor" path)
  if [[ -n "$path" ]]; then
    [[ -x "$path" ]] || { echo "$hypervisor is not executable: $path" >&2; return 1; }
  fi
  if [[ "$hypervisor" == qemu ]]; then
    machine=$(hypervisor_value "$config" qemu machine_type)
    firmware=$(hypervisor_value "$config" qemu firmware)
    [[ -n "$machine" ]] || { echo "QEMU machine_type is empty in $config" >&2; return 1; }
    "$path" -machine help | awk -v machine="$machine" \
      '$1 == machine { found = 1 } END { exit !found }' || {
      echo "QEMU does not support configured machine type: $machine" >&2
      return 1
    }
    [[ -f "$firmware" ]] || { echo "QEMU firmware not found: $firmware" >&2; return 1; }
  fi
}

check_environment() {
  local module_path candidate
  [[ $EUID -eq 0 ]] || { echo "run as root" >&2; return 2; }
  PVM_HOST_MODULE="${PVM_HOST_MODULE:-}"
  for candidate in "$PVM_HOST_MODULE" kvm_pvm kvm_amd; do
    [[ -n "$candidate" ]] || continue
    module_path="$(modinfo -n "$candidate" 2>/dev/null || true)"
    [[ "$module_path" == */updates/pvm-oot/* ]] || continue
    PVM_HOST_MODULE="$candidate"
    break
  done
  [[ -n "$PVM_HOST_MODULE" ]]
  if ! grep -q "^${PVM_HOST_MODULE} " /proc/modules; then
    modprobe -r kvm_amd kvm_intel kvm_pvm kvm 2>/dev/null || {
      echo "cannot switch KVM vendor module; stop active VMs first" >&2
      return 1
    }
  fi
  modprobe "$PVM_HOST_MODULE"
  module_path="$(modinfo -n "$PVM_HOST_MODULE")"
  [[ "$module_path" == */updates/pvm-oot/* ]]
  grep -q "^${PVM_HOST_MODULE} " /proc/modules
  [[ -c /dev/kvm ]]
  [[ -x "$RUNNER" ]]
  command -v python3 >/dev/null
  [[ "$(file -Lb "$GUEST_KERNEL")" == ELF* ]]
  echo "host=$(uname -r) module=$PVM_HOST_MODULE path=$module_path"
  echo "guest=$(readlink -f "$GUEST_KERNEL")"
}

run_one() {
  local hypervisor="$1" id status=0
  [[ -n "${CONFIGS[$hypervisor]:-}" ]] || {
    echo "unknown hypervisor: $hypervisor" >&2
    exit 2
  }
  preflight_hypervisor "$hypervisor"
  id="pvm-${hypervisor}-$(date +%s)-$$"
  echo "=== Kata PVM: $hypervisor ==="
  dmesg -C
  KATA_RUNTIME="${RUNTIMES[$hypervisor]}" \
    KATA_CONFIG_SOURCE="${CONFIGS[$hypervisor]}" \
    KATA_CONFIGURE_QBOOT=0 \
    KATA_USE_RUNTIME_CONFIG_PATH=1 \
    timeout --foreground --signal=TERM --kill-after=10 180 "$RUNNER" run "$id" || status=$?
  if dmesg | grep -Eqi 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode'; then
    echo "host kernel reported an error during the $hypervisor test" >&2
    dmesg >&2
    status=1
  fi
  return "$status"
}

check_environment
case "${1:-all}" in
  all)
    status=0
    for hypervisor in qemu dragonball clh; do
      if ! run_one "$hypervisor"; then
        echo "KATA_PVM_${hypervisor^^}=FAIL" >&2
        status=1
      else
        echo "KATA_PVM_${hypervisor^^}=PASS"
      fi
    done
    exit "$status"
    ;;
  qemu|clh|dragonball)
    run_one "$1"
    ;;
  *)
    echo "usage: $0 [all|qemu|clh|dragonball]" >&2
    exit 2
    ;;
esac
