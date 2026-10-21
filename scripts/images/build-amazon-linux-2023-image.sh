#!/usr/bin/env bash
set -euo pipefail

RELEASE=${AL2023_RELEASE:-2023.12.20261016.0}
WORK_DIR=${AL2023_WORK_DIR:-$HOME/pvm/distro-oot/amazon-linux-2023}
SHARED_BASE=${PVM_SHARED_BASE:-$HOME/pvm/images/ubuntu-24.04-official-pvm-oot-20260827/builddisk-120g.qcow2}
ROOT_SIZE=${AL2023_ROOT_SIZE:-80G}

IMAGE_NAME="al2023-kvm-$RELEASE-kernel-6.1-x86_64.xfs.gpt.qcow2"
IMAGE_URL="https://cdn.amazonlinux.com/al2023/os-images/$RELEASE/kvm"
OFFICIAL="$WORK_DIR/official"
VM_DIR="$WORK_DIR/vm"
BASE_IMAGE="$OFFICIAL/$IMAGE_NAME"
ROOT_DISK="$VM_DIR/root.qcow2"
SHARED_DISK="$VM_DIR/shared-work.qcow2"
KEY="$VM_DIR/id_ed25519"
SEED_DIR="$VM_DIR/seed"
SEED_ISO="$VM_DIR/seed.iso"

for tool in curl sha256sum qemu-img genisoimage ssh-keygen python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }
done
[[ -f "$SHARED_BASE" ]] || { echo "missing shared base: $SHARED_BASE" >&2; exit 2; }
mkdir -p "$OFFICIAL" "$SEED_DIR"

without_proxy() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "$@"
}

without_proxy curl --fail --location --retry 3 \
  --output "$OFFICIAL/SHA256SUMS" "$IMAGE_URL/SHA256SUMS"
expected=$(awk -v name="$IMAGE_NAME" '$2 == name || $2 == "*" name { print $1; exit }' "$OFFICIAL/SHA256SUMS")
[[ -n "$expected" ]] || { echo "checksum not found for $IMAGE_NAME" >&2; exit 1; }
if [[ ! -f "$BASE_IMAGE" || "$(sha256sum "$BASE_IMAGE" | awk '{print $1}')" != "$expected" ]]; then
  without_proxy curl --fail --location --retry 3 --continue-at - \
    --output "$BASE_IMAGE" "$IMAGE_URL/$IMAGE_NAME"
fi
printf '%s  %s\n' "$expected" "$BASE_IMAGE" | sha256sum -c -

if [[ ! -e "$ROOT_DISK" ]]; then
  qemu-img convert -f qcow2 -O qcow2 "$BASE_IMAGE" "$ROOT_DISK"
  qemu-img resize "$ROOT_DISK" "$ROOT_SIZE"
fi
if [[ ! -e "$SHARED_DISK" ]]; then
  qemu-img create -f qcow2 -F qcow2 -b "$(realpath "$SHARED_BASE")" "$SHARED_DISK"
else
  actual=$(qemu-img info --output=json "$SHARED_DISK" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("full-backing-filename", ""))')
  [[ "$actual" == "$(realpath "$SHARED_BASE")" ]] || {
    echo "shared overlay backing mismatch: $actual" >&2
    exit 1
  }
fi
[[ -e "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
public_key=$(<"$KEY.pub")

cat > "$SEED_DIR/meta-data" <<EOF
instance-id: pvm-al2023-$RELEASE
local-hostname: pvm-al2023
EOF
cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
hostname: pvm-al2023
manage_etc_hosts: true
users:
  - name: ec2-user
    groups: [wheel]
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
    mkdir -p /build
    if ! grep -q ' /build ' /etc/fstab; then
      echo '/dev/disk/by-id/virtio-pvm-shared /build ext4 defaults,nofail 0 2' >> /etc/fstab
    fi
    mountpoint -q /build || mount /build
EOF
genisoimage -quiet -output "$SEED_ISO" -volid cidata -joliet -rock \
  "$SEED_DIR/user-data" "$SEED_DIR/meta-data"

{
  printf 'release=%s\nimage_url=%s/%s\nshared_base=%s\n' \
    "$RELEASE" "$IMAGE_URL" "$IMAGE_NAME" "$(realpath "$SHARED_BASE")"
  sha256sum "$BASE_IMAGE" "$SEED_ISO"
  qemu-img info "$ROOT_DISK"
  qemu-img info "$SHARED_DISK"
} > "$VM_DIR/image-manifest.txt"
printf 'ROOT_DISK=%s\nSHARED_DISK=%s\nSEED_ISO=%s\nSSH_KEY=%s\n' \
  "$ROOT_DISK" "$SHARED_DISK" "$SEED_ISO" "$KEY"
