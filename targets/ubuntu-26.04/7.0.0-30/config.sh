#!/usr/bin/env bash

PVM_TARGET_NAME=ubuntu-26.04-7.0.0-30
PVM_KERNEL_RELEASE=7.0.0-30-generic
PVM_SOURCE_DIR=/build/pvm-pr29/ubuntu-7.0.0-30-prepared
PVM_BASE_NAME=host-pvm-612-oot-pr29
PVM_BASE_COMMIT=d7518a5b7016186cce5f3f1951efb4ce347e6dc1
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_LOAD_MODULE=kvm_pvm
PVM_LOADED_MODULE=kvm_pvm
PVM_MODULE_FILE=kvm-pvm.ko
PVM_ARTIFACT_DIR=/build/pvm-pr29/artifacts/ubuntu-26.04/7.0.0-30
PVM_JOBS=${PVM_JOBS:-8}

PVM_VM_PASSWORD=${PVM_VM_PASSWORD:-root}
pvm_vm_exec() {
  local remote_command=$1 quoted_password quoted_command
  printf -v quoted_password '%q' "$PVM_VM_PASSWORD"
  printf -v quoted_command '%q' "$remote_command"
  ssh validation-host \
    "sshpass -p $quoted_password ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 3337 root@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='test "$(uname -r)" = 7.0.0-30-generic && command -v gcc-15 >/dev/null && command -v make >/dev/null && command -v rpmbuild >/dev/null && command -v modprobe >/dev/null && test -d /lib/modules/7.0.0-30-generic/build && test -s "$PVM_SOURCE_DIR/.pvm-oot-prepared.json"'
PVM_BUILD_COMMAND='make -C "/lib/modules/$PVM_KERNEL_RELEASE/build" M="$PVM_SOURCE_DIR/$PVM_MODULE_SUBDIR" PVM_OOT_MODE=1 CC=gcc-15 -j"$PVM_JOBS" modules'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/kata/bin/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /opt/pvm-test/firecracker-pvm-test.sh /opt/pvm-test/firecracker-pvm-u26-runtime.json'
