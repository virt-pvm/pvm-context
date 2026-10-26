#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=${1:-}
KATA_CONFIG=${2:-}
OUTPUT=${3:-/opt/kata/share/kata-containers/vmlinux.pvm}
JOBS=${PVM_JOBS:-$(nproc)}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -d "$SOURCE_DIR" && -f "$KATA_CONFIG" ]] || {
  echo "usage: $0 <source-dir> <kata-kernel-config> [output]" >&2
  exit 2
}

BUILD_DIR=/build/pvm/build/guest-kernel
ARTIFACT_DIR=/build/pvm/artifacts
make -C "$SOURCE_DIR" mrproper
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR" "$(dirname "$OUTPUT")"
cp "$KATA_CONFIG" "$BUILD_DIR/.config"
"$SOURCE_DIR/scripts/config" --file "$BUILD_DIR/.config" \
  --enable X86_PIE \
  --enable PVM_GUEST
make -C "$SOURCE_DIR" O="$BUILD_DIR" olddefconfig
grep -qx 'CONFIG_X86_PIE=y' "$BUILD_DIR/.config"
grep -qx 'CONFIG_PVM_GUEST=y' "$BUILD_DIR/.config"
make -C "$SOURCE_DIR" O="$BUILD_DIR" -j"$JOBS" vmlinux
install -m 0644 "$BUILD_DIR/vmlinux" "$OUTPUT"
kernel_release=$(make -s -C "$SOURCE_DIR" O="$BUILD_DIR" kernelrelease)
printf '%s\n' "$kernel_release" > "$OUTPUT.uname"
file "$OUTPUT"
sha256sum "$OUTPUT" > "$ARTIFACT_DIR/guest-kernel.sha256"
printf '%s\n' "source=$SOURCE_DIR" "kata_config=$KATA_CONFIG" \
  "kata_config_sha256=$(sha256sum "$KATA_CONFIG" | awk '{print $1}')" \
  "kernel_release=$kernel_release" \
  "CONFIG_X86_PIE=y" \
  "CONFIG_PVM_GUEST=y" > "$ARTIFACT_DIR/guest-kernel.manifest"
