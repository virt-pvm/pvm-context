#!/usr/bin/env bash
set -euo pipefail

decode_var() {
  local encoded_name=$1 output_name=$2
  printf -v "$output_name" '%s' "$(printf '%s' "${!encoded_name}" | base64 -d)"
}

decode_var PVM_TARGET_NAME_B64 PVM_TARGET_NAME
decode_var PVM_KERNEL_RELEASE_B64 PVM_KERNEL_RELEASE
decode_var PVM_SOURCE_DIR_B64 PVM_SOURCE_DIR
decode_var PVM_BASE_NAME_B64 PVM_BASE_NAME
decode_var PVM_BASE_COMMIT_B64 PVM_BASE_COMMIT
decode_var PVM_MODULE_SUBDIR_B64 PVM_MODULE_SUBDIR
decode_var PVM_REQUIRED_MODULES_B64 PVM_REQUIRED_MODULES
decode_var PVM_LOAD_MODULE_B64 PVM_LOAD_MODULE
decode_var PVM_LOADED_MODULE_B64 PVM_LOADED_MODULE
decode_var PVM_MODULE_FILE_B64 PVM_MODULE_FILE
decode_var PVM_ARTIFACT_DIR_B64 PVM_ARTIFACT_DIR
decode_var PVM_JOBS_B64 PVM_JOBS
decode_var PVM_PREPARE_COMMAND_B64 PVM_PREPARE_COMMAND
decode_var PVM_CC_B64 PVM_CC
decode_var PVM_RESOLVE_BTFIDS_B64 PVM_RESOLVE_BTFIDS
decode_var PVM_CLEAN_COMMAND_B64 PVM_CLEAN_COMMAND
decode_var PVM_BUILD_COMMAND_B64 PVM_BUILD_COMMAND
decode_var PVM_INSTALL_COMMAND_B64 PVM_INSTALL_COMMAND
decode_var PVM_POST_TEST_COMMAND_B64 PVM_POST_TEST_COMMAND
decode_var PVM_POST_TEST_TIMEOUT_B64 PVM_POST_TEST_TIMEOUT

if [[ $EUID -ne 0 ]]; then
  echo "guest build must run as root" >&2
  exit 2
fi
if [[ "$PVM_KERNEL_RELEASE" == auto ]]; then
  PVM_KERNEL_RELEASE=$(uname -r)
fi

export PVM_TARGET_NAME PVM_KERNEL_RELEASE PVM_SOURCE_DIR PVM_MODULE_SUBDIR
export PVM_ARTIFACT_DIR PVM_JOBS PVM_CC PVM_RESOLVE_BTFIDS
MODULE_DIR="$PVM_SOURCE_DIR/$PVM_MODULE_SUBDIR"
KERNEL_BUILD="/lib/modules/$PVM_KERNEL_RELEASE/build"

[[ -d "$MODULE_DIR" ]] || { echo "module source not found: $MODULE_DIR" >&2; exit 2; }
[[ -d "$KERNEL_BUILD" ]] || { echo "kernel build tree not found: $KERNEL_BUILD" >&2; exit 2; }

echo "== prepare: $PVM_TARGET_NAME ($PVM_KERNEL_RELEASE) =="
bash -o pipefail -c "$PVM_PREPARE_COMMAND" </dev/null
command -v rpmbuild >/dev/null || { echo "rpmbuild is not installed" >&2; exit 2; }

[[ $(uname -r) == "$PVM_KERNEL_RELEASE" ]] || { echo "running kernel does not match target: $PVM_KERNEL_RELEASE" >&2; exit 2; }
kernel_cc=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "$KERNEL_BUILD/.config")
build_cc=$("$PVM_CC" --version | head -n 1)
[[ -n "$kernel_cc" && "$build_cc" == "$kernel_cc" ]] || {
  echo "compiler mismatch: kernel=$kernel_cc build=$build_cc" >&2
  exit 2
}

btf_modules=$(sed -n 's/^CONFIG_DEBUG_INFO_BTF_MODULES=//p' "$KERNEL_BUILD/.config")
if [[ "$btf_modules" == y ]]; then
  command -v pahole >/dev/null || { echo "pahole is required for module BTF" >&2; exit 2; }
  configured_pahole=$(sed -n 's/^CONFIG_PAHOLE_VERSION=//p' "$KERNEL_BUILD/.config")
  pahole_version=$(pahole --version)
  pahole_version=${pahole_version#v}
  pahole_major=${pahole_version%%.*}
  pahole_minor=${pahole_version#*.}
  pahole_minor=${pahole_minor%%.*}
  [[ $pahole_major =~ ^[0-9]+$ && $pahole_minor =~ ^[0-9]+$ ]] || { echo "invalid pahole version: $pahole_version" >&2; exit 2; }
  build_pahole=$((10#$pahole_major * 100 + 10#$pahole_minor))
  [[ "$build_pahole" == "$configured_pahole" ]] || {
    echo "pahole mismatch: kernel=$configured_pahole build=$build_pahole" >&2
    exit 2
  }
  if [[ ! -e "$KERNEL_BUILD/vmlinux" ]]; then
    btf_base="$PVM_ARTIFACT_DIR/btf/$PVM_KERNEL_RELEASE.vmlinux.btf"
    install -d "$(dirname -- "$btf_base")"
    install -m 0444 /sys/kernel/btf/vmlinux "$btf_base"
    ln -s "$btf_base" "$KERNEL_BUILD/vmlinux"
  fi
  if [[ -L "$KERNEL_BUILD/vmlinux" ]]; then
    cmp -s /sys/kernel/btf/vmlinux "$KERNEL_BUILD/vmlinux" || { echo "module BTF base does not match running kernel" >&2; exit 2; }
  fi
  resolver=${PVM_RESOLVE_BTFIDS:-$KERNEL_BUILD/tools/bpf/resolve_btfids/resolve_btfids}
  [[ -x "$resolver" ]] || { echo "resolve_btfids is missing: $resolver" >&2; exit 2; }
fi
echo "toolchain: $build_cc; pahole: ${pahole_version:-not required}; BTF modules: $btf_modules"

if [[ -z "$PVM_CLEAN_COMMAND" ]]; then
  PVM_CLEAN_COMMAND='find "$PVM_SOURCE_DIR/virt/kvm" -maxdepth 1 -type f \( -name "*.o" -o -name ".*.o.cmd" -o -name ".*.o.d" \) -delete && make -C "/lib/modules/$PVM_KERNEL_RELEASE/build" M="$PVM_SOURCE_DIR/$PVM_MODULE_SUBDIR" PVM_OOT_MODE=1 clean'
fi
if [[ -z "$PVM_BUILD_COMMAND" ]]; then
  if [[ -n "$PVM_RESOLVE_BTFIDS" ]]; then
    PVM_BUILD_COMMAND='make -C "/lib/modules/$PVM_KERNEL_RELEASE/build" M="$PVM_SOURCE_DIR/$PVM_MODULE_SUBDIR" PVM_OOT_MODE=1 CC="$PVM_CC" RESOLVE_BTFIDS="$PVM_RESOLVE_BTFIDS" -j"$PVM_JOBS" modules'
  else
    PVM_BUILD_COMMAND='make -C "/lib/modules/$PVM_KERNEL_RELEASE/build" M="$PVM_SOURCE_DIR/$PVM_MODULE_SUBDIR" PVM_OOT_MODE=1 CC="$PVM_CC" -j"$PVM_JOBS" modules'
  fi
fi

echo "== clean modules =="
bash -o pipefail -c "$PVM_CLEAN_COMMAND" </dev/null
echo "== build modules =="
bash -o pipefail -c "$PVM_BUILD_COMMAND" </dev/null

wrapper_header="$MODULE_DIR/include/linux/kvm_host.h"
if [[ -f "$wrapper_header" ]]; then
  wrapper_dependency='include/linux/../../../../../include/linux/kvm_host.h'
  for object in kvm_main coalesced_mmio; do
    command_file="$PVM_SOURCE_DIR/virt/kvm/.$object.o.cmd"
    [[ -f "$command_file" ]] || { echo "missing command file: $command_file" >&2; exit 1; }
    grep -Fq "$wrapper_dependency" "$command_file" || {
      echo "$object.o was not rebuilt with the OOT kvm_host.h wrapper" >&2
      exit 1
    }
  done
fi

read -r -a required_modules <<< "$PVM_REQUIRED_MODULES"
(( ${#required_modules[@]} > 0 )) || { echo "PVM_REQUIRED_MODULES is empty" >&2; exit 2; }
for module in "${required_modules[@]}"; do
  [[ -s "$MODULE_DIR/$module" ]] || { echo "missing module: $MODULE_DIR/$module" >&2; exit 1; }
  if [[ "$btf_modules" == y ]]; then
    readelf -S "$MODULE_DIR/$module" | grep -Eq '[[:space:]]\.BTF[[:space:]]' || {
      echo "module BTF is missing: $MODULE_DIR/$module" >&2
      exit 1
    }
  fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
safe_kernel=${PVM_KERNEL_RELEASE//-/.}
safe_kernel=${safe_kernel//[^A-Za-z0-9._+~]/_}
package_name="pvm-kmod-$safe_kernel"
package_version=1.0
source_root="$work/$package_name-$package_version"
topdir="$work/rpmbuild"
mkdir -p "$source_root/modules" "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cp -a "${required_modules[@]/#/$MODULE_DIR/}" "$source_root/modules/"

cat > "$source_root/manifest.txt" <<EOF
target=$PVM_TARGET_NAME
kernel_release=$PVM_KERNEL_RELEASE
source_dir=$PVM_SOURCE_DIR
base_name=$PVM_BASE_NAME
base_commit=$PVM_BASE_COMMIT
compiler=$build_cc
pahole=${pahole_version:-not required}
btf_modules=$btf_modules
build_command=$PVM_BUILD_COMMAND
clean_command=$PVM_CLEAN_COMMAND
build_time_utc=$(date -u +%FT%TZ)
EOF
(cd "$source_root" && sha256sum modules/*.ko) >> "$source_root/manifest.txt"
tar -C "$work" -czf "$topdir/SOURCES/$package_name-$package_version.tar.gz" \
  "$package_name-$package_version"

cat > "$topdir/SPECS/$package_name.spec" <<EOF
%global debug_package %{nil}

Name:           $package_name
Version:        $package_version
Release:        1
Summary:        PVM out-of-tree KVM modules for $PVM_KERNEL_RELEASE
License:        GPL-2.0-only
BuildArch:      x86_64
Source0:        %{name}-%{version}.tar.gz
Provides:       pvm-oot-kmod-$safe_kernel = %{version}-%{release}
Obsoletes:      pvm-oot-kmod-$safe_kernel <= %{version}-%{release}

%description
PVM out-of-tree KVM modules built for $PVM_KERNEL_RELEASE.

%prep
%setup -q

%build

%install
install -d %{buildroot}/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot
install -m 0644 modules/*.ko %{buildroot}/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/
install -d %{buildroot}/usr/share/doc/%{name}
install -m 0644 manifest.txt %{buildroot}/usr/share/doc/%{name}/manifest.txt

%post
/sbin/depmod -a $PVM_KERNEL_RELEASE || true

%postun
/sbin/depmod -a $PVM_KERNEL_RELEASE || true

%files
/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/*.ko
/usr/share/doc/%{name}/manifest.txt
EOF

echo "== build RPM =="
rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/$package_name.spec"
rpm_path=$(find "$topdir/RPMS" -type f -name '*.rpm' -print -quit)
[[ -n "$rpm_path" ]] || { echo "RPM was not produced" >&2; exit 1; }
mkdir -p "$PVM_ARTIFACT_DIR"
install -m 0644 "$rpm_path" "$PVM_ARTIFACT_DIR/"
install -m 0644 "$source_root/manifest.txt" "$PVM_ARTIFACT_DIR/$package_name.manifest.txt"
rpm_path="$PVM_ARTIFACT_DIR/$(basename -- "$rpm_path")"
sha256sum "$rpm_path" > "$rpm_path.sha256"
rpm -qpl "$rpm_path"

if [[ -z "$PVM_INSTALL_COMMAND" ]]; then
  PVM_INSTALL_COMMAND='rpm -Uvh --nodeps --replacepkgs "$rpm_path"'
fi
export rpm_path
echo "== install and load =="
bash -o pipefail -c "$PVM_INSTALL_COMMAND" </dev/null
depmod -a "$PVM_KERNEL_RELEASE"
modprobe -r kvm_pvm kvm_amd kvm_intel kvm 2>/dev/null || true
modprobe "$PVM_LOAD_MODULE"
module_path=$(modinfo -n "$PVM_LOAD_MODULE")
[[ "$module_path" == "/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/$PVM_MODULE_FILE" ]]
grep -q "^${PVM_LOADED_MODULE} " /proc/modules
if [[ "$btf_modules" == y ]]; then
  [[ -s "/sys/kernel/btf/$PVM_LOADED_MODULE" ]] || { echo "loaded module BTF is missing: $PVM_LOADED_MODULE" >&2; exit 1; }
  for module in "${required_modules[@]}"; do
    installed_module="/lib/modules/$PVM_KERNEL_RELEASE/updates/pvm-oot/$module"
    readelf -S "$installed_module" | grep -Eq '[[:space:]]\.BTF[[:space:]]' || {
      echo "installed module BTF is missing: $installed_module" >&2
      exit 1
    }
    module_name=${module%.ko}
    module_name=${module_name//-/_}
    if grep -q "^${module_name} " /proc/modules; then
      [[ -s "/sys/kernel/btf/$module_name" ]] || { echo "loaded module BTF is missing: $module_name" >&2; exit 1; }
    fi
  done
fi

echo "== post-install test =="
timeout --foreground "$PVM_POST_TEST_TIMEOUT" \
  bash -o pipefail -c "$PVM_POST_TEST_COMMAND" </dev/null
echo "PVM_OOT_RPM=$rpm_path"
cat "$rpm_path.sha256"
