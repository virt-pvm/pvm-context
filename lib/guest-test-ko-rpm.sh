#!/usr/bin/env bash
set -euo pipefail

decode_var() {
  local encoded_name=$1 output_name=$2
  printf -v "$output_name" '%s' "$(printf '%s' "${!encoded_name}" | base64 -d)"
}
decode_var PVM_TARGET_NAME_B64 PVM_TARGET_NAME
decode_var PVM_KERNEL_RELEASE_B64 PVM_KERNEL_RELEASE
decode_var PVM_REQUIRED_MODULES_B64 PVM_REQUIRED_MODULES
decode_var PVM_LOAD_MODULE_B64 PVM_LOAD_MODULE
decode_var PVM_LOADED_MODULE_B64 PVM_LOADED_MODULE
decode_var PVM_MODULE_FILE_B64 PVM_MODULE_FILE
decode_var PVM_INSTALL_COMMAND_B64 PVM_INSTALL_COMMAND
decode_var PVM_POST_TEST_COMMAND_B64 PVM_POST_TEST_COMMAND
decode_var PVM_POST_TEST_TIMEOUT_B64 PVM_POST_TEST_TIMEOUT
decode_var PVM_RPM_PATH_B64 rpm_path

[[ $EUID -eq 0 ]] || { echo "RPM validation must run as root" >&2; exit 2; }
[[ $(uname -r) == "$PVM_KERNEL_RELEASE" ]] || { echo "running kernel does not match target" >&2; exit 2; }
[[ -s $rpm_path ]] || { echo "RPM is missing: $rpm_path" >&2; exit 2; }
rpm -qpl "$rpm_path" | grep -Fq "/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/$PVM_MODULE_FILE" || {
  echo "RPM does not contain the target module" >&2; exit 2;
}
if [[ -z $PVM_INSTALL_COMMAND ]]; then
  PVM_INSTALL_COMMAND='rpm -Uvh --nodeps --replacepkgs "$rpm_path"'
fi
export rpm_path PVM_TARGET_NAME PVM_KERNEL_RELEASE
echo "== install RPM and load module =="
bash -o pipefail -c "$PVM_INSTALL_COMMAND" </dev/null
depmod -a "$PVM_KERNEL_RELEASE"
modprobe -r kvm_pvm kvm_amd kvm_intel kvm 2>/dev/null || true
modprobe "$PVM_LOAD_MODULE"
module_path=$(modinfo -n "$PVM_LOAD_MODULE")
[[ $module_path == "/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/$PVM_MODULE_FILE" ]] || {
  echo "loaded module is not from the RPM: $module_path" >&2; exit 1;
}
grep -q "^${PVM_LOADED_MODULE} " /proc/modules
if grep -q '^CONFIG_DEBUG_INFO_BTF_MODULES=y$' "/lib/modules/$PVM_KERNEL_RELEASE/build/.config"; then
  read -r -a required_modules <<< "$PVM_REQUIRED_MODULES"
  for module in "${required_modules[@]}"; do
    installed="/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/$module"
    readelf -S "$installed" | grep -E '[[:space:]]\.BTF[[:space:]]' >/dev/null || {
      echo "installed module BTF is missing: $installed" >&2; exit 1;
    }
  done
  [[ -s /sys/kernel/btf/$PVM_LOADED_MODULE ]] || {
    echo "loaded module BTF is missing" >&2; exit 1;
  }
fi
echo "== runtime test =="
timeout --foreground "$PVM_POST_TEST_TIMEOUT" bash -o pipefail -c "$PVM_POST_TEST_COMMAND" </dev/null
echo "PVM_RPM_TEST=PASS"
