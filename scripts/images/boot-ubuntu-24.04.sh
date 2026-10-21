#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
ACTION=${1:-start}
PROFILE=${2:-"$ROOT_DIR/configs/ubuntu-24.04-basic.env"}

# shellcheck source=/dev/null
source "$PROFILE"
PVM_WORK_DIR=${PVM_WORK_DIR:-"$ROOT_DIR/.artifacts/ubuntu-24.04-basic"}
VM_MACHINE_TYPE=${VM_MACHINE_TYPE:-q35}
ROOT_DISK="$PVM_WORK_DIR/ubuntu-24.04.qcow2"
SHARED_DISK=${PVM_SHARED_OVERLAY:-"$PVM_WORK_DIR/shared.qcow2"}
SEED_ISO="$PVM_WORK_DIR/seed.iso"
SSH_KEY="$PVM_WORK_DIR/id_ed25519"
PID_FILE="$PVM_WORK_DIR/qemu.pid"
SERIAL_LOG="$PVM_WORK_DIR/serial.log"

is_running() {
  [[ -s "$PID_FILE" ]] || return 1
  if [[ "$QEMU_USE_SUDO" == 1 ]]; then
    sudo -n kill -0 "$(sudo -n cat "$PID_FILE")" 2>/dev/null
  else
    kill -0 "$(<"$PID_FILE")" 2>/dev/null
  fi
}

qemu_pid() {
  if [[ "$QEMU_USE_SUDO" == 1 ]]; then sudo -n cat "$PID_FILE"; else cat "$PID_FILE"; fi
}

case "$ACTION" in
  start)
    is_running && { echo "VM already running: $(qemu_pid)"; exit 0; }
    "$SCRIPT_DIR/build-ubuntu-24.04-image.sh" "$PROFILE"
    command -v "$QEMU_BIN" >/dev/null || { echo "QEMU not found: $QEMU_BIN" >&2; exit 2; }
    "$QEMU_BIN" -machine help | awk -v machine="$VM_MACHINE_TYPE" \
      '$1 == machine { found = 1 } END { exit !found }' || {
      echo "QEMU does not support VM machine type: $VM_MACHINE_TYPE" >&2
      exit 2
    }
    [[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable" >&2; exit 1; }
    : > "$SERIAL_LOG"
    qemu_args=(
      -name pvm-u2404-basic
      -machine "$VM_MACHINE_TYPE,accel=kvm"
      -cpu host
      -m "$VM_MEMORY"
      -smp "$VM_CPUS"
      -display none
      -serial "file:$SERIAL_LOG"
      -boot order=c,strict=on
      -device virtio-net-pci,netdev=net0
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22"
      -drive "if=none,id=root,format=qcow2,file=$ROOT_DISK"
      -device virtio-blk-pci,drive=root,serial=pvm-root,bootindex=1
      -drive "if=none,id=seed,format=raw,readonly=on,file=$SEED_ISO"
      -device virtio-blk-pci,drive=seed,serial=cidata
      -drive "if=none,id=shared,format=qcow2,file=$SHARED_DISK"
      -device virtio-blk-pci,drive=shared,serial=pvm-shared
      -daemonize
      -pidfile "$PID_FILE"
    )
    [[ -n "$QEMU_DATA_DIR" ]] && qemu_args=(-L "$QEMU_DATA_DIR" "${qemu_args[@]}")
    if [[ "$QEMU_USE_SUDO" == 1 ]]; then
      sudo -n "$QEMU_BIN" "${qemu_args[@]}"
    else
      "$QEMU_BIN" "${qemu_args[@]}"
    fi
    if [[ -n "$QEMU_CGROUP_PROCS" ]]; then
      qemu_pid | sudo -n tee "$QEMU_CGROUP_PROCS" >/dev/null
    fi

    for _ in $(seq 1 120); do
      ssh_options=(
        -i "$SSH_KEY"
        -p "$VM_SSH_PORT"
        -o BatchMode=yes
        -o ConnectTimeout=2
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
      )
      if ssh -q "${ssh_options[@]}" "$VM_SSH_USER@127.0.0.1" true; then
        ssh "${ssh_options[@]}" "$VM_SSH_USER@127.0.0.1" 'cloud-init status --wait && mountpoint -q /build'
        echo "VM_SSH=ssh -i $SSH_KEY -p $VM_SSH_PORT $VM_SSH_USER@127.0.0.1"
        exit 0
      fi
      sleep 2
    done
    echo "VM did not become ready; see $SERIAL_LOG" >&2
    exit 1
    ;;
  stop)
    if is_running; then
      if [[ "$QEMU_USE_SUDO" == 1 ]]; then
        sudo -n kill "$(qemu_pid)"
      else
        kill "$(qemu_pid)"
      fi
      for _ in $(seq 1 30); do
        is_running || break
        sleep 1
      done
    fi
    is_running && { echo "VM did not stop" >&2; exit 1; }
    [[ "$QEMU_USE_SUDO" == 1 ]] && sudo -n rm -f "$PID_FILE" || rm -f "$PID_FILE"
    ;;
  status)
    if is_running; then
      echo "running pid=$(qemu_pid)"
    else
      echo "stopped"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status} [profile]" >&2
    exit 2
    ;;
esac
