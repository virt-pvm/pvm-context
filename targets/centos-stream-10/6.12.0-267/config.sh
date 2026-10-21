#!/usr/bin/env bash

PVM_TARGET_NAME=centos-stream-10-6.12.0-267
PVM_KERNEL_RELEASE=6.12.0-267.el10.x86_64
PVM_SOURCE_DIR=/opt/pvm-oot-src/centos-stream-10-6.12.0-267
PVM_BASE_NAME=host-pvm-612-oot-pr29
PVM_BASE_COMMIT=3f8daf19fd3e5a7e7c9cbf987b7d6d1cc3cf79c2
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_ARTIFACT_DIR=${PVM_ARTIFACT_DIR:-/root/pvm-artifacts-pr29/centos-stream-10/6.12.0-267}
PVM_JOBS=${PVM_JOBS:-8}

PVM_VM_PASSWORD=${PVM_VM_PASSWORD:-root}
pvm_vm_exec() {
  local remote_command=$1 quoted_password quoted_command
  printf -v quoted_password '%q' "$PVM_VM_PASSWORD"
  printf -v quoted_command '%q' "$remote_command"
  ssh validation-host \
    "sshpass -p $quoted_password ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 3338 root@127.0.0.1 $quoted_command"
}

PVM_PREPARE_COMMAND='
set -e
test "$(uname -r)" = 6.12.0-267.el10.x86_64
command -v gcc >/dev/null
command -v make >/dev/null
command -v rpmbuild >/dev/null
command -v modprobe >/dev/null
test -d /lib/modules/6.12.0-267.el10.x86_64/build
if ! command -v pahole >/dev/null; then
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY dnf install -y dwarves
fi
'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/pvm-test/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /opt/pvm-test/firecracker-pvm-test.sh /opt/pvm-test/firecracker-pvm-cs10-runtime.json'
