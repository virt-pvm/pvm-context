#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
PROFILE=${1:-"$ROOT_DIR/configs/ubuntu-24.04-basic.env"}

[[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$PROFILE"

PVM_WORK_DIR=${PVM_WORK_DIR:-"$ROOT_DIR/.artifacts/ubuntu-24.04-basic"}
VM_MACHINE_TYPE=${VM_MACHINE_TYPE:-q35}
IMAGE_DIR="$PVM_WORK_DIR/images"
SEED_DIR="$PVM_WORK_DIR/seed"
BASE_IMAGE="$IMAGE_DIR/$UBUNTU_IMAGE_NAME"
ROOT_DISK="$PVM_WORK_DIR/ubuntu-24.04.qcow2"
SHARED_DISK=${PVM_SHARED_OVERLAY:-"$PVM_WORK_DIR/shared.qcow2"}
SEED_ISO="$PVM_WORK_DIR/seed.iso"
SSH_KEY="$PVM_WORK_DIR/id_ed25519"

for command in curl "$QEMU_IMG_BIN" sha256sum ssh-keygen; do
  command -v "$command" >/dev/null || {
    echo "missing host command: $command" >&2
    exit 2
  }
done

if command -v genisoimage >/dev/null; then
  ISO_BUILDER=genisoimage
elif command -v mkisofs >/dev/null; then
  ISO_BUILDER=mkisofs
else
  echo "missing host command: genisoimage or mkisofs" >&2
  exit 2
fi

mkdir -p "$IMAGE_DIR" "$SEED_DIR"

download() {
  local url=$1 output=$2
  [[ -s "$output" ]] && return
  curl --fail --location --retry 3 --output "$output.part" "$url"
  mv "$output.part" "$output"
}

download "$UBUNTU_IMAGE_BASE_URL/$UBUNTU_IMAGE_NAME" "$BASE_IMAGE"
download "$UBUNTU_IMAGE_BASE_URL/SHA256SUMS" "$IMAGE_DIR/SHA256SUMS"
(
  cd "$IMAGE_DIR"
  expected=$(awk -v name="$UBUNTU_IMAGE_NAME" '$2 == name || $2 == "*" name { print $1; exit }' SHA256SUMS)
  [[ -n "$expected" ]] || { echo "checksum missing for $UBUNTU_IMAGE_NAME" >&2; exit 1; }
  printf '%s  %s\n' "$expected" "$UBUNTU_IMAGE_NAME" | sha256sum -c -
)

if [[ ! -f "$ROOT_DISK" ]]; then
  "$QEMU_IMG_BIN" convert -f qcow2 -O qcow2 "$BASE_IMAGE" "$ROOT_DISK"
  "$QEMU_IMG_BIN" resize "$ROOT_DISK" "$ROOT_DISK_SIZE"
fi
if [[ -n "$PVM_SHARED_BASE" ]]; then
  QEMU_IMG_BIN="$QEMU_IMG_BIN" \
    "$SCRIPT_DIR/create-shared-overlay.sh" "$PVM_SHARED_BASE" "$SHARED_DISK"
elif [[ ! -f "$SHARED_DISK" ]]; then
  "$QEMU_IMG_BIN" create -f qcow2 "$SHARED_DISK" "$SHARED_DISK_SIZE"
fi
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
fi

public_key=$(<"$SSH_KEY.pub")
cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
hostname: pvm-u2404
manage_etc_hosts: true
users:
  - name: $VM_SSH_USER
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
disable_root: true
growpart:
  mode: auto
  devices: [/]
resize_rootfs: true
runcmd:
  - |
    set -eu
    device=/dev/disk/by-id/virtio-pvm-shared
    for attempt in \$(seq 1 30); do
      [ -b "\$device" ] && break
      sleep 1
    done
    [ -b "\$device" ]
    if ! blkid "\$device" >/dev/null 2>&1; then
      mkfs.ext4 -F -L pvm-shared "\$device"
    fi
    mkdir -p /build
    sed -i '\|[[:space:]]/build[[:space:]]|d' /etc/fstab
    echo "/dev/disk/by-id/virtio-pvm-shared /build ext4 defaults,nofail 0 2" >> /etc/fstab
    mountpoint -q /build || mount /build
    mkdir -p /build/pvm
    chown $VM_SSH_USER:$VM_SSH_USER /build/pvm
EOF

cat > "$SEED_DIR/meta-data" <<EOF
instance-id: pvm-u2404-basic
local-hostname: pvm-u2404
EOF

"$ISO_BUILDER" -quiet -output "$SEED_ISO" -volid cidata -joliet -rock \
  "$SEED_DIR/user-data" "$SEED_DIR/meta-data"

{
  printf 'ubuntu_image_url=%s/%s\n' "$UBUNTU_IMAGE_BASE_URL" "$UBUNTU_IMAGE_NAME"
  printf 'vm_machine_type=%s\n' "$VM_MACHINE_TYPE"
  sha256sum "$BASE_IMAGE" "$ROOT_DISK" "$SEED_ISO"
  "$QEMU_IMG_BIN" info "$ROOT_DISK"
  [[ -z "$PVM_SHARED_BASE" ]] || "$QEMU_IMG_BIN" info "$PVM_SHARED_BASE"
  "$QEMU_IMG_BIN" info "$SHARED_DISK"
} > "$PVM_WORK_DIR/image-manifest.txt"

printf 'ROOT_DISK=%s\nSHARED_DISK=%s\nSEED_ISO=%s\nSSH_KEY=%s\n' "$ROOT_DISK" "$SHARED_DISK" "$SEED_ISO" "$SSH_KEY"
