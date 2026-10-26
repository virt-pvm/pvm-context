#!/usr/bin/env bash

PVM_TARGET_NAME=ubuntu-24.04-6.8.0-139
PVM_KERNEL_RELEASE=6.8.0-139-generic
PVM_SOURCE_DIR=/build/pvm/src/pvm-oot-pr29/ubuntu-24.04-6.8.0-139
PVM_BASE_NAME=host-pvm-66-oot-pr29
PVM_BASE_COMMIT=81ef364558b11440e497cbc624ea3ece27196aa5
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_ARTIFACT_DIR=${PVM_ARTIFACT_DIR:-/build/pvm/artifacts/rpm-pr29/ubuntu-24.04/6.8.0-139}
PVM_CC=x86_64-linux-gnu-gcc-13
PVM_JOBS=${PVM_JOBS:-8}

pvm_vm_exec() {
  local remote_command=$1 quoted_command
  : "${PVM_SSH_HOST:?set PVM_SSH_HOST in the local config}"
  : "${PVM_VM_PORT:?set PVM_VM_PORT in the local config}"
  : "${PVM_VM_KEY:?set PVM_VM_KEY in the local config}"
  printf -v quoted_command '%q' "sudo -n env $remote_command"
  ssh "$PVM_SSH_HOST" \
    "ssh -i $PVM_VM_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PVM_VM_PORT pvm@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='command -v x86_64-linux-gnu-gcc-13 >/dev/null && command -v make >/dev/null && command -v rpmbuild >/dev/null && command -v modprobe >/dev/null && test -d /lib/modules/6.8.0-139-generic/build'
PVM_POST_TEST_COMMAND='PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /build/pvm/context/scripts/firecracker-pvm-test.sh /build/pvm/context/scripts/firecracker-pvm.json'
