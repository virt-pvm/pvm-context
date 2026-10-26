#!/usr/bin/env bash

# The host receives only VM identity and disk paths, never guest credentials.
pvm_vm_ensure() {
  local root_dir=$1 host_command value quoted name
  local -a names=(
    PVM_VM_NAME PVM_VM_PORT PVM_VM_ROOT_DISK PVM_VM_SHARED_DISK
    PVM_VM_SEED_ISO PVM_VM_CPUS PVM_VM_MEMORY PVM_VM_PIDFILE
    PVM_VM_SERIAL_LOG PVM_QEMU_BIN PVM_QEMU_SHARE PVM_VM_USE_SUDO
    PVM_VM_CGROUP_PROCS
  )
  : "${PVM_SSH_HOST:?set PVM_SSH_HOST in the local env}"
  : "${PVM_VM_NAME:?set PVM_VM_NAME in the local env}"
  : "${PVM_VM_ROOT_DISK:?set PVM_VM_ROOT_DISK in the local env}"
  : "${PVM_VM_SHARED_DISK:?set PVM_VM_SHARED_DISK in the local env}"
  : "${PVM_VM_PORT:?set PVM_VM_PORT in the local env}"
  host_command="env"
  for name in "${names[@]}"; do
    value=${!name:-}
    printf -v quoted '%q' "$value"
    host_command+=" $name=$quoted"
  done
  host_command+=" bash -s"
  pvm_host_exec "$host_command" < "$root_dir/scripts/vm/ensure-qemu.sh"
}
