#!/usr/bin/env bash

PVM_TARGET_NAME=amazon-linux-2023-6.18.54-121.166
PVM_KERNEL_RELEASE=6.18.54-121.166.amzn2023.x86_64
PVM_SOURCE_DIR=/build/pvm-pr29/amazon-6.18-prepared
PVM_BASE_NAME=host-pvm-612-oot-pr29
PVM_BASE_COMMIT=d7518a5b7016186cce5f3f1951efb4ce347e6dc1
PVM_REQUIRED_MODULES='kvm.ko kvm-pvm.ko'
PVM_LOAD_MODULE=kvm_pvm
PVM_LOADED_MODULE=kvm_pvm
PVM_MODULE_FILE=kvm-pvm.ko
PVM_ARTIFACT_DIR=${PVM_ARTIFACT_DIR:-/build/pvm-pr29/artifacts/amazon-linux-2023/6.18.54-121.166}
PVM_JOBS=${PVM_JOBS:-8}
PVM_RESOLVE_BTFIDS=/build/pvm-pr29/artifacts/amazon-6.18-btf/resolve_btfids/resolve_btfids

PVM_VM_KEY=${PVM_VM_KEY:-/path/on/validation-host/to/id_ed25519}
PVM_VM_PORT=${PVM_VM_PORT:-3340}
pvm_vm_exec() {
  local remote_command=$1
  ssh validation-host \
    "ssh -i $PVM_VM_KEY -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PVM_VM_PORT ec2-user@127.0.0.1 \"sudo -n bash -c '$remote_command'\""
}

PVM_PREPARE_COMMAND='
set -e
test "$(uname -r)" = 6.18.54-121.166.amzn2023.x86_64
grep -qw nokaslr /proc/cmdline
command -v gcc >/dev/null
command -v make >/dev/null
command -v rpmbuild >/dev/null
test -d /lib/modules/6.18.54-121.166.amzn2023.x86_64/build
test -s "$PVM_SOURCE_DIR/.pvm-oot-prepared.json"
if ! command -v pahole >/dev/null; then
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY dnf install -y dwarves
fi
if ! test -x "$PVM_RESOLVE_BTFIDS"; then
  mkdir -p "$(dirname "$PVM_RESOLVE_BTFIDS")"
  make -C /build/host-6.12.33-base/tools/bpf/resolve_btfids OUTPUT="$(dirname "$PVM_RESOLVE_BTFIDS")/" -j"$PVM_JOBS"
fi
'
PVM_POST_TEST_COMMAND='FIRECRACKER=/opt/kata/bin/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /build/pvm-pr29/tests/firecracker-pvm-test.sh /build/pvm-pr29/tests/firecracker-pvm.json'
