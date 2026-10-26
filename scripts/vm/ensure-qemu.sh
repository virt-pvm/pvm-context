#!/usr/bin/env bash
set -euo pipefail

: "${PVM_VM_NAME:?}"
: "${PVM_VM_PORT:?}"
: "${PVM_VM_ROOT_DISK:?}"
: "${PVM_VM_SHARED_DISK:?}"
[[ $PVM_VM_PORT =~ ^[0-9]+$ ]] || { echo "invalid VM port" >&2; exit 2; }
[[ $PVM_VM_NAME =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "invalid VM name" >&2; exit 2; }

drive_file() {
  local spec=$1 part
  IFS=, read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    [[ $part == file=* ]] && { printf '%s\n' "${part#file=}"; return; }
  done
}

check_running_vm() {
  local pid=$1 state=${2:-already-running} name= port= root= shared= option spec id part
  local -a argv parts
  mapfile -d '' -t argv < "/proc/$pid/cmdline" || return 1
  for ((i=0; i<${#argv[@]}; i++)); do
    option=${argv[i]}
    case $option in
      -name) name=${argv[i+1]:-} ;;
      -netdev)
        spec=${argv[i+1]:-}
        [[ $spec == *"hostfwd=tcp:127.0.0.1:$PVM_VM_PORT-:22"* ]] && port=$PVM_VM_PORT
        ;;
      -drive)
        spec=${argv[i+1]:-}
        id=
        IFS=, read -r -a parts <<< "$spec"
        for part in "${parts[@]}"; do
          [[ $part == id=* ]] && id=${part#id=}
        done
        case $id in
          root) root=$(drive_file "$spec") ;;
          shared) shared=$(drive_file "$spec") ;;
        esac
        ;;
    esac
  done
  [[ $name == "$PVM_VM_NAME" ]] || return 1
  if [[ $port != "$PVM_VM_PORT" || $root != "$PVM_VM_ROOT_DISK" ||
        $shared != "$PVM_VM_SHARED_DISK" ]]; then
    printf 'VM identity mismatch: name=%s pid=%s port=%s root=%s shared=%s\n' \
      "$name" "$pid" "$port" "$root" "$shared" >&2
    return 2
  fi
  printf 'VM_STATE=%s name=%s pid=%s port=%s\n' "$state" "$name" "$pid" "$port"
}

matching_pid() {
  ps -eo pid=,args= | awk -v name="$PVM_VM_NAME" '
    $2 ~ /(^|\/)(qemu-system-x86_64|qemu-kvm)$/ {
      for (i = 2; i <= NF; i++) {
        if ($i == "-name" && $(i + 1) == name) print $1
      }
    }'
}

pids=$(matching_pid)
if [[ -n $pids ]]; then
  [[ $(wc -w <<< "$pids") == 1 ]] || { echo "multiple QEMU processes match $PVM_VM_NAME" >&2; exit 1; }
  check_running_vm "$pids"
  exit $?
fi

PVM_QEMU_BIN=${PVM_QEMU_BIN:-qemu-system-x86_64}
PVM_VM_CPUS=${PVM_VM_CPUS:-4}
PVM_VM_MEMORY=${PVM_VM_MEMORY:-8G}
PVM_VM_USE_SUDO=${PVM_VM_USE_SUDO:-0}
PVM_VM_PIDFILE=${PVM_VM_PIDFILE:-"${PVM_VM_ROOT_DISK%.qcow2}.pvm-context.pid"}
PVM_VM_SERIAL_LOG=${PVM_VM_SERIAL_LOG:-"${PVM_VM_ROOT_DISK%.qcow2}.pvm-context.serial.log"}
[[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable" >&2; exit 1; }
for path in "$PVM_VM_ROOT_DISK" "$PVM_VM_SHARED_DISK"; do
  [[ -f $path ]] || { echo "VM disk is missing: $path" >&2; exit 1; }
done
if [[ -n ${PVM_VM_SEED_ISO:-} ]]; then
  [[ -f $PVM_VM_SEED_ISO ]] || { echo "VM seed is missing: $PVM_VM_SEED_ISO" >&2; exit 1; }
fi
if ss -ltn "( sport = :$PVM_VM_PORT )" | tail -n +2 | grep -q .; then
  echo "VM port $PVM_VM_PORT is already in use" >&2
  exit 1
fi

qemu_args=(
  -name "$PVM_VM_NAME" -machine q35,accel=kvm -cpu host
  -m "$PVM_VM_MEMORY" -smp "$PVM_VM_CPUS"
  -display none -serial "file:$PVM_VM_SERIAL_LOG" -monitor none
  -boot order=c,strict=on
  -device virtio-net-pci,netdev=net0
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PVM_VM_PORT-:22"
  -drive "if=none,id=root,format=qcow2,file=$PVM_VM_ROOT_DISK"
  -device virtio-blk-pci,drive=root,serial=pvm-root,bootindex=1
)
if [[ -n ${PVM_VM_SEED_ISO:-} ]]; then
  qemu_args+=(
    -drive "if=none,id=seed,format=raw,readonly=on,file=$PVM_VM_SEED_ISO"
    -device virtio-blk-pci,drive=seed,serial=cidata
  )
fi
qemu_args+=(
  -drive "if=none,id=shared,format=qcow2,file=$PVM_VM_SHARED_DISK"
  -device virtio-blk-pci,drive=shared,serial=pvm-shared
  -daemonize -pidfile "$PVM_VM_PIDFILE"
)
[[ -n ${PVM_QEMU_SHARE:-} ]] && qemu_args=(-L "$PVM_QEMU_SHARE" "${qemu_args[@]}")
if [[ $PVM_VM_USE_SUDO == 1 ]]; then
  sudo -n "$PVM_QEMU_BIN" "${qemu_args[@]}"
else
  "$PVM_QEMU_BIN" "${qemu_args[@]}"
fi
if [[ -n ${PVM_VM_CGROUP_PROCS:-} ]]; then
  if [[ $PVM_VM_USE_SUDO == 1 ]]; then
    sudo -n sh -c 'cat "$1" > "$2"' sh "$PVM_VM_PIDFILE" "$PVM_VM_CGROUP_PROCS"
  else
    cat "$PVM_VM_PIDFILE" > "$PVM_VM_CGROUP_PROCS"
  fi
fi
sleep 2
pids=$(matching_pid)
[[ $(wc -w <<< "$pids") == 1 ]] || { echo "VM did not start cleanly" >&2; exit 1; }
check_running_vm "$pids" started
