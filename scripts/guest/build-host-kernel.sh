#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=${1:-}
KERNEL_RELEASE=${2:-}
JOBS=${PVM_JOBS:-$(nproc)}
LOG_DIR=/build/pvm/logs/host-kernel-$KERNEL_RELEASE

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -n "$SOURCE_DIR" && -n "$KERNEL_RELEASE" && -x "$SOURCE_DIR/scripts/config" ]] || {
  echo "usage: $0 <source-dir> <kernel-release>" >&2
  exit 2
}

mkdir -p "$LOG_DIR"
cd "$SOURCE_DIR"
saved_config=$(mktemp)
if [[ -f .config ]]; then
  cp .config "$saved_config"
fi
make mrproper
if [[ -s "$saved_config" ]]; then
  cp "$saved_config" .config
else
  cp "/boot/config-$(uname -r)" .config
fi
rm -f "$saved_config"

scripts/config --file .config \
  --set-str LOCALVERSION "" \
  --disable LOCALVERSION_AUTO \
  --set-str SYSTEM_TRUSTED_KEYS "" \
  --set-str SYSTEM_REVOCATION_KEYS "" \
  --enable DEBUG_INFO \
  --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
  --enable DEBUG_INFO_BTF \
  --disable DEBUG_INFO_BTF_MODULES
make olddefconfig

actual=$(make -s kernelrelease)
[[ "$actual" == "$KERNEL_RELEASE" ]] || {
  echo "expected kernel release $KERNEL_RELEASE, got $actual" >&2
  exit 1
}

make -j"$JOBS" bzImage modules 2>&1 | tee "$LOG_DIR/build.log"
make INSTALL_MOD_STRIP=1 modules_install 2>&1 | tee "$LOG_DIR/modules-install.log"
install -m 0644 arch/x86/boot/bzImage "/boot/vmlinuz-$KERNEL_RELEASE"
install -m 0644 System.map "/boot/System.map-$KERNEL_RELEASE"
install -m 0644 .config "/boot/config-$KERNEL_RELEASE"
ln -sfnT "$SOURCE_DIR" "/lib/modules/$KERNEL_RELEASE/build"
ln -sfnT "$SOURCE_DIR" "/lib/modules/$KERNEL_RELEASE/source"
update-initramfs -c -k "$KERNEL_RELEASE"
update-grub

sha256sum "/boot/vmlinuz-$KERNEL_RELEASE" > "/build/pvm/artifacts/host-kernel-$KERNEL_RELEASE.sha256"
echo "host kernel $KERNEL_RELEASE is installed"
