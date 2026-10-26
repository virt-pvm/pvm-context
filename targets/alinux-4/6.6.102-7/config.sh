#!/usr/bin/env bash

PVM_TARGET_NAME=alinux-4-6.6.102-7
PVM_KERNEL_RELEASE=6.6.102-7.alnx4.x86_64
PVM_SOURCE_DIR=/opt/pvm-oot-src/alinux-4-6.6.102-7-readonly
PVM_BASE_NAME=host-pvm-66-oot-pr29
PVM_BASE_COMMIT=81ef364558b11440e497cbc624ea3ece27196aa5
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_ARTIFACT_DIR=${PVM_ARTIFACT_DIR:-/root/pvm-artifacts-pr29/alinux-4/6.6.102-7}
PVM_JOBS=${PVM_JOBS:-8}

pvm_vm_exec() {
  local remote_command=$1 quoted_password quoted_command
  : "${PVM_SSH_HOST:?set PVM_SSH_HOST in the local config}"
  : "${PVM_VM_PORT:?set PVM_VM_PORT in the local config}"
  : "${PVM_VM_PASSWORD:?set PVM_VM_PASSWORD in the local config}"
  printf -v quoted_password '%q' "$PVM_VM_PASSWORD"
  printf -v quoted_command '%q' "$remote_command"
  ssh "$PVM_SSH_HOST" \
    "sshpass -p $quoted_password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PVM_VM_PORT root@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='command -v pahole >/dev/null || dnf install -y dwarves; command -v gcc >/dev/null && command -v make >/dev/null && command -v rpmbuild >/dev/null && command -v modprobe >/dev/null && test -d /lib/modules/6.6.102-7.alnx4.x86_64/build'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/pvm-test/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /opt/pvm-test/firecracker-pvm-test.sh /opt/pvm-test/firecracker-pvm-cs10-runtime.json'
