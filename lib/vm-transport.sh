#!/usr/bin/env bash

pvm_host_exec() {
  if [[ ${PVM_SSH_HOST:-} == local ]]; then
    bash -c "$1"
  else
    ssh -T -o ConnectTimeout=10 -o ConnectionAttempts=1 "${PVM_SSH_HOST:?}" "$1"
  fi
}

# Connection details come from an ignored local profile, never from target pins.
pvm_vm_exec() {
  local guest_command=$1 guest_quoted target_quoted key_quoted host_command
  : "${PVM_SSH_HOST:?set PVM_SSH_HOST in the local env}"
  : "${PVM_VM_PORT:?set PVM_VM_PORT in the local env}"
  : "${PVM_VM_USER:?set PVM_VM_USER in the local env}"
  [[ $PVM_VM_PORT =~ ^[0-9]+$ ]] || { echo "invalid VM port" >&2; return 2; }

  printf -v guest_quoted '%q' "$guest_command"
  if [[ $PVM_VM_USER == root ]]; then
    guest_command="bash -lc $guest_quoted"
  else
    guest_command="sudo -n bash -lc $guest_quoted"
  fi
  printf -v guest_quoted '%q' "$guest_command"
  printf -v target_quoted '%q' "$PVM_VM_USER@127.0.0.1"

  local known_hosts=
  if [[ -n ${PVM_VM_KNOWN_HOSTS:-} ]]; then
    printf -v known_hosts ' -o UserKnownHostsFile=%q' "$PVM_VM_KNOWN_HOSTS"
  fi
  if [[ -n ${PVM_VM_KEY:-} ]]; then
    printf -v key_quoted '%q' "$PVM_VM_KEY"
    host_command="ssh -T -F /dev/null -i $key_quoted -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new$known_hosts -p $PVM_VM_PORT $target_quoted $guest_quoted"
    pvm_host_exec "$host_command"
  elif [[ -n ${PVM_VM_PASSWORD:-} ]]; then
    host_command="IFS= read -r SSHPASS; export SSHPASS; exec sshpass -e ssh -T -F /dev/null -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new -p $PVM_VM_PORT $target_quoted $guest_quoted"
    { printf '%s\n' "$PVM_VM_PASSWORD"; cat; } | pvm_host_exec "$host_command"
  else
    echo "set PVM_VM_KEY or PVM_VM_PASSWORD in the local env" >&2
    return 2
  fi
}
