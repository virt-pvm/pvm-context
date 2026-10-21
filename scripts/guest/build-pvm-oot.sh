#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=${1:-}
KERNEL_RELEASE=${2:-$(uname -r)}
LINE=${3:-}
JOBS=${PVM_JOBS:-$(nproc)}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -n "$SOURCE_DIR" && -n "$LINE" ]] || {
  echo "usage: $0 <source-dir> [kernel-release] <66|612>" >&2
  exit 2
}
[[ "$LINE" == 66 || "$LINE" == 612 ]] || { echo "line must be 66 or 612" >&2; exit 2; }

MODULE_DIR="$SOURCE_DIR/arch/x86/kvm"
KERNEL_BUILD="/lib/modules/$KERNEL_RELEASE/build"
INSTALL_DIR="/lib/modules/$KERNEL_RELEASE/updates/pvm-oot"
ARTIFACT_DIR="/build/pvm/artifacts/oot/$LINE/$KERNEL_RELEASE"

[[ -d "$MODULE_DIR" ]] || { echo "module source not found: $MODULE_DIR" >&2; exit 2; }
[[ -d "$KERNEL_BUILD" ]] || { echo "kernel headers not found: $KERNEL_BUILD" >&2; exit 2; }

find "$SOURCE_DIR/virt/kvm" -maxdepth 1 -type f \( -name '*.o' -o -name '.*.o.cmd' -o -name '.*.o.d' \) -delete
make -C "$KERNEL_BUILD" M="$MODULE_DIR" PVM_OOT_MODE=1 clean
make -C "$KERNEL_BUILD" M="$MODULE_DIR" PVM_OOT_MODE=1 -j"$JOBS" modules

mapfile -t modules < <(find "$MODULE_DIR" -maxdepth 1 -type f -name '*.ko' -print | sort)
(( ${#modules[@]} > 0 )) || { echo "no modules were produced" >&2; exit 1; }
printf '%s\n' "${modules[@]}" | grep -q '/kvm\.ko$'
printf '%s\n' "${modules[@]}" | grep -q '/kvm-pvm\.ko$'
load_module=kvm_pvm
module_file=kvm-pvm.ko

install -d -m 0755 "$INSTALL_DIR" "$ARTIFACT_DIR"
install -m 0644 "${modules[@]}" "$INSTALL_DIR/"
install -m 0644 "${modules[@]}" "$ARTIFACT_DIR/"
depmod -a "$KERNEL_RELEASE"

{
  printf 'line=%s\nkernel_release=%s\nsource_dir=%s\n' "$LINE" "$KERNEL_RELEASE" "$SOURCE_DIR"
  if [[ -f "$SOURCE_DIR/.pvm-source-manifest" ]]; then
    cat "$SOURCE_DIR/.pvm-source-manifest"
  elif git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" rev-parse HEAD | sed 's/^/commit=/'
    if ! git -C "$SOURCE_DIR" diff --quiet --ignore-submodules HEAD; then
      echo 'dirty=true'
    else
      echo 'dirty=false'
    fi
  else
    echo 'commit=unavailable'
    echo 'dirty=unknown'
  fi
  sha256sum "$ARTIFACT_DIR"/*.ko
} > "$ARTIFACT_DIR/manifest.txt"

if [[ "$KERNEL_RELEASE" == "$(uname -r)" ]]; then
  modprobe -r kvm_pvm kvm_amd kvm_intel kvm 2>/dev/null || {
    echo "cannot unload active KVM modules; stop all VMs first" >&2
    exit 1
  }
  modprobe "$load_module"
  actual=$(modinfo -n "$load_module")
  [[ "$actual" == "$INSTALL_DIR/$module_file" ]] || {
    echo "unexpected module path: $actual" >&2
    exit 1
  }
  [[ -c /dev/kvm ]]
fi

cat "$ARTIFACT_DIR/manifest.txt"
