#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=${AL2023_WORK_DIR:-$HOME/pvm/distro-oot/amazon-linux-2023}
VM_DIR="$WORK_DIR/vm"
QEMU=${QEMU_BIN:-$HOME/qemu/build/qemu-system-x86_64}
QEMU_SHARE=${QEMU_SHARE:-$HOME/qemu/build/qemu-bundle/usr/local/share/qemu}
SSH_PORT=${AL2023_SSH_PORT:-3340}
PIDFILE="$VM_DIR/qemu.pid"

for file in "$QEMU" "$VM_DIR/root.qcow2" "$VM_DIR/shared-work.qcow2" "$VM_DIR/seed.iso"; do
  [[ -e "$file" ]] || { echo "missing $file" >&2; exit 2; }
done
if [[ -f "$PIDFILE" ]] && kill -0 "$(<"$PIDFILE")" 2>/dev/null; then
  echo "already running: pid $(<"$PIDFILE")"
  exit 0
fi

sudo -n "$QEMU" -L "$QEMU_SHARE" \
  -name pvm-al2023-618 -machine q35,accel=kvm -cpu host -m 8G -smp 8 \
  -display none -serial "file:$VM_DIR/serial.log" -boot order=c,strict=on \
  -device virtio-net-pci,netdev=net0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
  -drive "if=none,id=root,format=qcow2,file=$VM_DIR/root.qcow2" \
  -device virtio-blk-pci,drive=root,serial=pvm-root,bootindex=1 \
  -drive "if=none,id=seed,format=raw,readonly=on,file=$VM_DIR/seed.iso" \
  -device virtio-blk-pci,drive=seed,serial=cidata \
  -drive "if=none,id=shared,format=qcow2,file=$VM_DIR/shared-work.qcow2" \
  -device virtio-blk-pci,drive=shared,serial=pvm-shared \
  -daemonize -pidfile "$PIDFILE"
echo "VM started: SSH ec2-user@127.0.0.1:$SSH_PORT"
