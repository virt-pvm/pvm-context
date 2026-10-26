#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
ACTION=${1:-all}
PROFILE=${2:-"$ROOT_DIR/configs/ubuntu-24.04-basic.env"}

[[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$PROFILE"
PVM_WORK_DIR=${PVM_WORK_DIR:-"$ROOT_DIR/.artifacts/ubuntu-24.04-basic"}
PVM_GUEST_CONFIG=${PVM_GUEST_CONFIG:-}
SSH_KEY="$PVM_WORK_DIR/id_ed25519"
SSH_OPTIONS=(
  -T
  -i "$SSH_KEY"
  -p "$VM_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ServerAliveInterval=2
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
SCP_OPTIONS=(
  -i "$SSH_KEY"
  -P "$VM_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
REMOTE="$VM_SSH_USER@127.0.0.1"

vm_ssh() {
  ssh "${SSH_OPTIONS[@]}" "$REMOTE" "$@"
}

vm_copy() {
  scp "${SCP_OPTIONS[@]}" "$@"
}

require_worktree() {
  local name=$1 path=$2
  [[ -f "$path/Makefile" ]] || {
    echo "$name source tree is required; set it in $PROFILE" >&2
    exit 2
  }
}

sync_tree() {
  local source=$1 destination=$2
  local transport
  transport="ssh -i $SSH_KEY -p $VM_SSH_PORT -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  rsync -a --partial --delete --exclude='.git/' -e "$transport" "$source/" "$REMOTE:$destination/"
  {
    printf 'source=%s\n' "$source"
    if git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$source" rev-parse HEAD | sed 's/^/commit=/'
      if ! git -C "$source" diff --quiet --ignore-submodules HEAD; then
        echo 'dirty=true'
      else
        echo 'dirty=false'
      fi
    fi
  } | vm_ssh "cat > '$destination/.pvm-source-manifest'"
}

wait_for_ssh() {
  for _ in $(seq 1 120); do
    vm_ssh true >/dev/null 2>&1 && return
    sleep 2
  done
  echo "VM SSH did not return" >&2
  exit 1
}

wait_for_reboot() {
  local previous_boot_id=$1 current_boot_id
  for _ in $(seq 1 150); do
    current_boot_id=$(vm_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    if [[ -n "$current_boot_id" && "$current_boot_id" != "$previous_boot_id" ]]; then
      return
    fi
    sleep 2
  done
  echo "VM did not complete reboot" >&2
  exit 1
}

version_ge() {
  [[ $(printf '%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]
}

version_lt() {
  [[ "$1" != "$2" ]] && version_ge "$2" "$1"
}

stage_context() {
  context_paths=(
    scripts/guest
    scripts/kata
    scripts/firecracker
    scripts/firecracker-pvm-test.sh
    scripts/firecracker-pvm.json
    scripts/kata-pvm-test-all.sh
    scripts/kata-pvm-oci-test.sh
    scripts/attach-shared-runtime.sh
    scripts/containerd-shared.service
    scripts/docker-shared.service
    scripts/cubesandbox-pvm-test.sh
  )
  vm_ssh 'sudo install -d -o "$(id -u)" -g "$(id -g)" /build/pvm /build/pvm/context'
  tar -C "$ROOT_DIR" -czf - "${context_paths[@]}" |
    vm_ssh 'tar -C /build/pvm/context -xzf -'
}

has_shared_runtime() {
  vm_ssh 'test -x /build/pvm-shared/runtime/cubesandbox/Cubelet/bin/cubelet && test -d /build/pvm-shared/runtime/kata'
}

stage_dns_overrides() {
  local source_dir=${PVM_DNS_SCRIPTS_DIR:-"$ROOT_DIR/.artifacts/local-overrides/cubesandbox-dns"}
  local remote_dir=/build/pvm/context/.local-dns-overrides
  local target_dir=/build/pvm-shared/runtime/cubesandbox/scripts/systemd
  local name
  local -a scripts=(coredns-start.sh coredns-postcheck.sh dns-host-route-up.sh)

  for name in "${scripts[@]}"; do
    [[ -f "$source_dir/$name" ]] || {
      echo "CubeSandbox DNS override missing: $source_dir/$name" >&2
      exit 2
    }
  done
  vm_ssh "install -d -m 0755 '$remote_dir'"
  tar -C "$source_dir" -czf - "${scripts[@]}" |
    vm_ssh "tar -C '$remote_dir' -xzf -"
  for name in "${scripts[@]}"; do
    vm_ssh "test -f '$target_dir/common.sh' && sudo install -m 0755 '$remote_dir/$name' '$target_dir/$name' && cmp '$remote_dir/$name' '$target_dir/$name'"
  done
}

attach_shared_runtime() {
  local start_services=${1:-0}
  local install_packages=${2:-0}
  has_shared_runtime || {
    echo "shared runtime assets are missing from PVM_SHARED_BASE" >&2
    exit 1
  }
  stage_dns_overrides
  vm_ssh "sudo INSTALL_PACKAGES='$install_packages' START_SERVICES='$start_services' /build/pvm/context/scripts/attach-shared-runtime.sh"
}

stage_kata() {
  local remote_archive
  if [[ -n "$KATA_ARCHIVE" ]]; then
    [[ -f "$KATA_ARCHIVE" ]] || { echo "Kata archive not found: $KATA_ARCHIVE" >&2; exit 2; }
    remote_archive="/build/pvm/cache/$(basename "$KATA_ARCHIVE")"
    vm_copy "$KATA_ARCHIVE" "$REMOTE:$remote_archive"
  else
    remote_archive="/build/pvm/cache/$(basename "$KATA_ARCHIVE_URL")"
    vm_ssh "if ! test -s '$remote_archive'; then curl -fL --retry 3 -o '$remote_archive.part' '$KATA_ARCHIVE_URL'; mv '$remote_archive.part' '$remote_archive'; fi"
  fi
  if [[ -n "${KATA_ARCHIVE_SHA256:-}" ]]; then
    vm_ssh "printf '%s  %s\\n' '$KATA_ARCHIVE_SHA256' '$remote_archive' | sha256sum -c -"
  fi
  vm_ssh "sudo /build/pvm/context/scripts/kata/install-kata.sh '$remote_archive'"
}

stage_firecracker() {
  local remote_archive
  if [[ -n "$FIRECRACKER_ARCHIVE" ]]; then
    [[ -f "$FIRECRACKER_ARCHIVE" ]] || { echo "Firecracker archive not found: $FIRECRACKER_ARCHIVE" >&2; exit 2; }
    remote_archive="/build/pvm/cache/$(basename "$FIRECRACKER_ARCHIVE")"
    vm_copy "$FIRECRACKER_ARCHIVE" "$REMOTE:$remote_archive"
  else
    remote_archive="/build/pvm/cache/$(basename "$FIRECRACKER_ARCHIVE_URL")"
    vm_ssh "if ! test -s '$remote_archive'; then curl -fL --retry 3 -o '$remote_archive.part' '$FIRECRACKER_ARCHIVE_URL'; mv '$remote_archive.part' '$remote_archive'; fi"
  fi
  vm_ssh "printf '%s  %s\\n' '$FIRECRACKER_ARCHIVE_SHA256' '$remote_archive' | sha256sum -c -"
  vm_ssh "sudo /build/pvm/context/scripts/firecracker/install-firecracker.sh '$remote_archive' '$FIRECRACKER_VERSION'"
}

build_guest_kernel() {
  local guest_config source_config source_id
  require_worktree PVM_GUEST_SOURCE "$PVM_GUEST_SOURCE_WORKTREE"
  vm_ssh 'mkdir -p /build/pvm/src/guest /build/pvm/configs'
  sync_tree "$PVM_GUEST_SOURCE_WORKTREE" /build/pvm/src/guest
  if [[ -n "$PVM_GUEST_CONFIG" ]]; then
    source_config=$PVM_GUEST_CONFIG
  else
    source_config="$ROOT_DIR/.artifacts/guest-config/selected.config"
    if [[ ! -f "$source_config" ]]; then
      "$ROOT_DIR/scripts/guest/resolve-guest-config.sh" "$source_config"
    fi
    # shellcheck source=/dev/null
    source "$ROOT_DIR/pins/guest-config.env"
    [[ -s "$source_config.source" ]] || {
      echo "guest config provenance is missing: $source_config.source" >&2
      exit 2
    }
    source_id=$(<"$source_config.source")
    case "$source_id" in
      "repo:$PVM_GUEST_CONFIG_COMMIT:$PVM_GUEST_CONFIG_PATH")
        printf '%s  %s\n' "$PVM_GUEST_CONFIG_SHA256" "$source_config" | sha256sum -c -
        ;;
      override:*)
        (cd "$(dirname -- "$source_config")" && sha256sum -c "$(basename -- "$source_config").sha256")
        ;;
      *) echo "stale guest config source: $source_id" >&2; exit 2 ;;
    esac
  fi
  [[ -f "$source_config" ]] || { echo "guest config not found: $source_config" >&2; exit 2; }
  guest_config=/build/pvm/configs/kata-guest.config
  vm_copy "$source_config" "$REMOTE:$guest_config"
  vm_ssh "sudo PVM_JOBS='$PVM_JOBS' /build/pvm/context/scripts/guest/build-guest-kernel.sh /build/pvm/src/guest '$guest_config'"
  vm_ssh 'sudo /build/pvm/context/scripts/kata/configure-pvm-runtime.sh'
}

prepare() {
  "$ROOT_DIR/scripts/images/boot-ubuntu-24.04.sh" start "$PROFILE"
  stage_context
  vm_ssh 'sudo /build/pvm/context/scripts/guest/prepare-ubuntu-24.04.sh'
  vm_ssh 'sudo chown -R "$(id -u):$(id -g)" /build/pvm'
  if has_shared_runtime; then
    attach_shared_runtime 0 1
  else
    stage_kata
  fi
  stage_firecracker
  build_guest_kernel
}

build_host_kernel() {
  local line=$1 source release destination
  stage_context
  case "$line" in
    66)
      source=$PVM_66_BASE_SOURCE
      release=$PVM_66_KERNEL_RELEASE
      destination=/build/pvm/src/host-66-base
      ;;
    612)
      source=$PVM_612_BASE_SOURCE
      release=$PVM_612_KERNEL_RELEASE
      destination=/build/pvm/src/host-612-base
      ;;
    *) echo "unknown kernel line: $line" >&2; exit 2 ;;
  esac
  require_worktree "PVM_${line}_BASE" "$source"
  vm_ssh "mkdir -p '$destination'"
  sync_tree "$source" "$destination"
  vm_ssh "sudo PVM_JOBS='$PVM_JOBS' /build/pvm/context/scripts/guest/build-host-kernel.sh '$destination' '$release'"
}

select_kernel() {
  local release=$1 running previous_boot_id
  vm_ssh "sudo test -s '/boot/vmlinuz-$release'"
  vm_ssh "printf '%s\\n' 'GRUB_DEFAULT=saved' 'GRUB_CMDLINE_LINUX_DEFAULT=\"$PVM_HOST_CMDLINE\"' | sudo tee /etc/default/grub.d/90-pvm-context.cfg >/dev/null && sudo update-grub && sudo grub-set-default 'Advanced options for Ubuntu>Ubuntu, with Linux $release'"
  previous_boot_id=$(vm_ssh cat /proc/sys/kernel/random/boot_id)
  vm_ssh 'sudo reboot' || true
  wait_for_reboot "$previous_boot_id"
  running=$(vm_ssh uname -r)
  [[ "$running" == "$release" ]] || {
    echo "requested kernel $release, booted $running" >&2
    exit 1
  }
  vm_ssh "grep -qw nokaslr /proc/cmdline || { echo 'required host kernel argument nokaslr is missing' >&2; exit 1; }"
}

test_line() {
  local line=$1 source destination running
  stage_context
  vm_ssh 'sudo /build/pvm/context/scripts/kata/configure-pvm-runtime.sh'
  running=$(vm_ssh uname -r)
  case "$line" in
    66)
      require_worktree PVM_66_SOURCE "$PVM_66_SOURCE_WORKTREE"
      source=$PVM_66_SOURCE_WORKTREE
      destination=/build/pvm/src/host-66-oot
      version_ge "$running" 6.6 && version_lt "$running" 6.12 || {
        echo "6.6 OOT line requires 6.6 <= kernel < 6.12; got $running" >&2
        exit 1
      }
      ;;
    612)
      require_worktree PVM_612_SOURCE "$PVM_612_SOURCE_WORKTREE"
      source=$PVM_612_SOURCE_WORKTREE
      destination=/build/pvm/src/host-612-oot
      if ! version_ge "$running" 6.12 || ! version_lt "$running" 7.0; then
        echo "6.12 OOT line requires 6.12 <= kernel < 7.0; got $running" >&2
        exit 1
      fi
      ;;
  esac
  vm_ssh "mkdir -p '$destination'"
  sync_tree "$source" "$destination"
  vm_ssh "sudo PVM_JOBS='$PVM_JOBS' /build/pvm/context/scripts/guest/build-pvm-oot.sh '$destination' '$running' '$line'"
  if has_shared_runtime; then
    attach_shared_runtime 1 0
  fi
  vm_ssh 'sudo /build/pvm/context/scripts/firecracker-pvm-test.sh'
  vm_ssh 'sudo /build/pvm/context/scripts/kata-pvm-test-all.sh all'
  if has_shared_runtime; then
    vm_ssh 'sudo /build/pvm/context/scripts/cubesandbox-pvm-test.sh all'
  fi
}

case "$ACTION" in
  prepare) prepare ;;
  build-host-66) build_host_kernel 66 ;;
  build-host-612) build_host_kernel 612 ;;
  switch-66) select_kernel "$PVM_66_KERNEL_RELEASE" ;;
  test-66) test_line 66 ;;
  switch-612) select_kernel "$PVM_612_KERNEL_RELEASE" ;;
  test-612) test_line 612 ;;
  all)
    prepare
    build_host_kernel 66
    build_host_kernel 612
    select_kernel "$PVM_66_KERNEL_RELEASE"
    test_line 66
    select_kernel "$PVM_612_KERNEL_RELEASE"
    test_line 612
    ;;
  *)
    echo "usage: $0 {prepare|build-host-66|build-host-612|switch-66|test-66|switch-612|test-612|all} [profile]" >&2
    exit 2
    ;;
esac
