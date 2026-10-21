#!/usr/bin/env bash

PVM_TARGET_NAME=opencloudos-9.4-6.6.119-52.9
PVM_KERNEL_RELEASE=6.6.119-52.9.oc9.x86_64
PVM_SOURCE_DIR=/home/opencloudos/pvm-oot-src/opencloudos-9.4-6.6.119-52.9-2b93
PVM_BASE_NAME=host-pvm-66-oot-pr29
PVM_BASE_COMMIT=2b93c344e689377881e4c41fa2ffa34b89b75b7c
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_ARTIFACT_DIR=${PVM_ARTIFACT_DIR:-/root/pvm-artifacts-pr29/opencloudos-9.4/6.6.119-52.9}
PVM_JOBS=${PVM_JOBS:-8}
PVM_CC=gcc
PVM_RESOLVE_BTFIDS=/home/opencloudos/pvm-oot-tools/tools/bpf/resolve_btfids/resolve_btfids

PVM_VM_PASSWORD=${PVM_VM_PASSWORD:-opencloudos}
pvm_vm_exec() {
  local remote_command=$1 quoted_password quoted_command
  printf -v quoted_password '%q' "$PVM_VM_PASSWORD"
  printf -v quoted_command '%q' "sudo -n $remote_command"
  ssh validation-host \
    "sshpass -p $quoted_password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 3351 opencloudos@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='command -v gcc >/dev/null && command -v pahole >/dev/null && command -v make >/dev/null && command -v rpmbuild >/dev/null && test -x "$PVM_RESOLVE_BTFIDS" && test -f "$PVM_SOURCE_DIR/.pvm-oot-prepared.json" && test -d "/lib/modules/$PVM_KERNEL_RELEASE/build" && grep -qw nokaslr /proc/cmdline'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/pvm-test/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /opt/pvm-test/firecracker-pvm-test.sh /opt/pvm-test/firecracker-pvm-cs10-runtime.json'
PVM_POST_TEST_TIMEOUT=90
