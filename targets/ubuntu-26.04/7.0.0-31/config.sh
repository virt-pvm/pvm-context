#!/usr/bin/env bash

PVM_TARGET_NAME=ubuntu-26.04-7.0.0-31
PVM_KERNEL_RELEASE=7.0.0-31-generic
PVM_SOURCE_DIR=/opt/pvm-oot-src/ubuntu-26.04-7.0.0-31
PVM_BASE_NAME=host-pvm-612-oot-pr29
PVM_BASE_COMMIT=3f8daf19fd3e5a7e7c9cbf987b7d6d1cc3cf79c2
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_LOAD_MODULE=kvm_pvm
PVM_LOADED_MODULE=kvm_pvm
PVM_MODULE_FILE=kvm-pvm.ko
PVM_ARTIFACT_DIR=/root/pvm-artifacts-pr29/ubuntu-26.04/7.0.0-31
PVM_JOBS=${PVM_JOBS:-8}

PVM_VM_PASSWORD=${PVM_VM_PASSWORD:-root}
pvm_vm_exec() {
  local remote_command=$1 quoted_password quoted_command
  printf -v quoted_password '%q' "$PVM_VM_PASSWORD"
  printf -v quoted_command '%q' "$remote_command"
  ssh validation-host \
    "sshpass -p $quoted_password ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 3337 root@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='command -v gcc >/dev/null && command -v make >/dev/null && command -v rpmbuild >/dev/null && command -v modprobe >/dev/null && test -d /lib/modules/7.0.0-31-generic/build'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/kata/bin/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /opt/pvm-test/firecracker-pvm-test.sh /opt/pvm-test/firecracker-pvm-u26-runtime.json'
