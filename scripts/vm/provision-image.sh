#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "PVM_IMAGE_ERROR line=$LINENO" >&2; systemctl --failed --no-pager >&2 || true' ERR
ROOT=/var/lib/pvm-factory
CONTEXT=$ROOT/context
[[ $EUID == 0 ]] || { echo 'run inside the VM as root' >&2; exit 2; }
[[ -f $ROOT/config.json && -f /etc/cloud/cloud.cfg ]] || {
  echo 'not a factory cloud VM' >&2; exit 2;
}
eval "$(python3 - "$ROOT/config.json" <<'PY'
import json, shlex, sys
c = json.load(open(sys.argv[1]))
rpm_fields = {'kernel': c['kernel']}
if c['family'] == 'rpm':
    rpm_fields['version'], suffix = c['kernel'].split('-', 1)
    rpm_fields['release'], rpm_fields['arch'] = suffix.rsplit('.', 1)
for name, value in {
    'KERNEL': c['kernel'], 'CC': c['compiler'], 'JOBS': str(c['jobs']),
    'PROFILE': c['profile'], 'FAMILY': c['family'],
    'KERNEL_PACKAGE': c['kernel_package'].format(kernel=c['kernel']),
    'HEADERS_PACKAGE': c['headers_package'].format(kernel=c['kernel']),
    'KERNEL_SUPPORT': ' '.join(p.format(kernel=c['kernel']) for p in c.get('kernel_support_packages', [])),
    'KERNEL_RPMS': ' '.join(url.format(**rpm_fields) for url in c.get('kernel_rpms', [])),
    'COMPILER_PACKAGES': ' '.join(c.get('compiler_packages', ['gcc', 'gcc-c++'])),
    'EXTRA': ' '.join(c['packages']) + ' ' + c['PVM_EXTRA_PACKAGES'],
    'SNAPSHOT': c['PVM_APT_SNAPSHOT'], 'DEB_VERSION': c['PVM_KERNEL_DEB_VERSION'],
    'APT_MIRROR': c['PVM_APT_MIRROR'],
}.items():
    print(name + '=' + shlex.quote(value))
PY
)"
export PATH=/usr/local/bin:/usr/local/sbin:$PATH
BUILD=/lib/modules/$KERNEL/build

verify() {
  [[ $(uname -r) == "$KERNEL" ]] || { echo 'incorrect running kernel' >&2; return 1; }
  mountpoint -q /build
  [[ -f $BUILD/Module.symvers && -f $BUILD/.config && -s /sys/kernel/btf/vmlinux ]]
  python3 - "$ROOT/config.json" "$BUILD" <<'PY'
import hashlib, json, pathlib, subprocess, sys
c = json.load(open(sys.argv[1]))
p = json.load(open('/var/lib/pvm-factory/source/tool/' + c['profile']))
b = pathlib.Path(sys.argv[2])
for name, expected in p['target']['files_sha256'].items():
    actual = hashlib.sha256((b / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit('header checksum mismatch: ' + name)
lines = (b / '.config').read_text().splitlines()
values = dict(line.split('=', 1) for line in lines if line.startswith('CONFIG_') and '=' in line)
compiler = subprocess.check_output([c['compiler'], '--version']).decode().splitlines()[0]
if compiler != values['CONFIG_CC_VERSION_TEXT'].strip('"'):
    raise SystemExit('kernel compiler mismatch: ' + compiler)
pahole = subprocess.check_output(['pahole', '--version']).decode().strip().lstrip('v').split('.')
version = str(int(pahole[0]) * 100 + int(pahole[1]))
if version != values.get('CONFIG_PAHOLE_VERSION'):
    raise SystemExit('kernel pahole version mismatch: ' + version)
print('HEADERS_COMPILER_PAHOLE=PASS')
PY
  local resolver_status=0
  /usr/local/libexec/pvm/resolve_btfids --help >/dev/null 2>&1 || resolver_status=$?
  [[ $resolver_status == 0 || $resolver_status == 129 ]]
  for program in rpmbuild make pahole readelf modprobe; do command -v "$program"; done
  for hv in qemu dragonball clh; do
    test -s "/etc/kata-containers/pvm/configuration-$hv-pvm.toml" || {
      echo "missing Kata configuration: $hv" >&2; return 1;
    }
  done
  test -x /usr/local/bin/containerd-shim-kata-v2
  for unit in docker containerd cube-sandbox-s3lvol cube-sandbox-cubelet cube-sandbox-cube-egress; do
    systemctl is-active --quiet "$unit"
  done
  test -S /var/run/s3lvol.sock
  curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:3000/health >/dev/null
  local expected_dns actual_dns
  expected_dns=$(sed -n 's/^CUBE_SANDBOX_NODE_IP=//p' /build/pvm-shared/runtime/cubesandbox/.one-click.env | head -n1)
  actual_dns=$(getent ahostsv4 test.cube.app | awk 'NR == 1 {print $1}') || true
  [[ -n $expected_dns && $actual_dns == "$expected_dns" ]] || {
    echo "Cube DNS validation failed" >&2; return 1;
  }
  echo PVM_IMAGE_ENVIRONMENT=PASS
}

cube_storage_ready() (
  source /build/pvm-shared/runtime/cubesandbox/.one-click.env
  source /build/pvm-shared/runtime/cubesandbox/CubeS3lvol/scripts/rcow_common.sh
  local controller nqn state connected=0
  for controller in /sys/class/nvme/nvme*; do
    [[ -f $controller/subsysnqn ]] || continue
    read -r nqn < "$controller/subsysnqn"
    [[ $nqn == "$RCOW_NQN_PREFIX"* ]] || continue
    read -r state < "$controller/state"
    [[ $state == live ]] || return 1
    connected=$((connected + 1))
  done
  [[ $connected == "$RCOW_NUM_SUBSYS" ]]
)

runtime_ready() {
  local unit
  for unit in docker containerd cube-sandbox-cubelet cube-sandbox-s3lvol cube-sandbox-cube-egress cube-sandbox-coredns cube-sandbox-dns; do
    systemctl is-active --quiet "$unit" || return 1
  done
  # Type=simple is active before SPDK has restored and connected its grid.
  cube_storage_ready || return 1
  local expected_dns actual_dns
  expected_dns=$(sed -n 's/^CUBE_SANDBOX_NODE_IP=//p' /build/pvm-shared/runtime/cubesandbox/.one-click.env | head -n1)
  actual_dns=$(timeout 5 getent ahostsv4 test.cube.app | awk 'NR == 1 {print $1}') || true
  [[ -n $expected_dns && $actual_dns == "$expected_dns" ]] || return 1
  curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:3000/health >/dev/null 2>&1
}

if [[ ${1:-} == --verify || ${1:-} == --source ]]; then
  # The service graph starts asynchronously after boot.
  deadline=$((SECONDS + 300))
  until runtime_ready; do
    (( SECONDS < deadline )) || {
      systemctl --failed --no-pager
      journalctl -b -u cube-sandbox-cube-egress -u cube-sandbox-cubelet -u cube-sandbox-s3lvol -n 100 --no-pager
      exit 1
    }
    sleep 3
  done
  verify
  if [[ ${1:-} == --verify ]]; then
    exit 0
  fi
fi

if [[ ${1:-} == --source ]]; then
  [[ ! -e $ROOT/prepared ]] || { echo 'prepared source must be fresh' >&2; exit 1; }
  prepare_cc=$(python3 - "$ROOT/source/tool/$PROFILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['target']['compiler_version'].split()[0])
PY
)
  python3 "$ROOT/source/tool/tools/pvm-oot/prepare.py" \
    --profile "$ROOT/source/tool/$PROFILE" --source-export "$ROOT/source/baseline" \
    --kernel-build "$BUILD" --cc "$prepare_cc" --output "$ROOT/prepared"
  exit
fi
[[ $# == 0 ]] || { echo 'unknown provisioning option' >&2; exit 2; }

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
[[ ! -f $ROOT/prepare-hook.sh ]] || bash "$ROOT/prepare-hook.sh"
read -r -a extras <<< "$EXTRA"
read -r -a kernel_support <<< "$KERNEL_SUPPORT"
if [[ $FAMILY == ubuntu ]]; then
  export DEBIAN_FRONTEND=noninteractive
  if [[ -n $APT_MIRROR ]]; then
    python3 - "$APT_MIRROR" <<'PY'
from pathlib import Path
import re, sys
from urllib.parse import urlparse
mirror = sys.argv[1].rstrip('/')
if urlparse(mirror).scheme not in ('http', 'https') or not urlparse(mirror).hostname:
    raise SystemExit('invalid Ubuntu package mirror')
for p in list(Path('/etc/apt/sources.list.d').glob('*.sources')) + [Path('/etc/apt/sources.list')]:
    if p.exists():
        p.write_text(re.sub(r'https?://(?:[a-z]+\.)?(?:archive|security)\.ubuntu\.com/ubuntu/?', mirror, p.read_text()))
PY
  fi
  apt_args=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
  if [[ -n $SNAPSHOT ]]; then
    [[ $SNAPSHOT =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || exit 2
    apt_args+=(--snapshot "$SNAPSHOT")
  fi
  apt-get "${apt_args[@]}" update
  apt-get "${apt_args[@]}" install -y build-essential rpm dwarves libelf-dev libdw-dev \
    zlib1g-dev libssl-dev pkg-config flex bison bc python3 curl dnsmasq iproute2 \
    iptables libaio1t64 nvme-cli xfsprogs jq rsync git file kmod "${extras[@]}"
  if [[ -n $DEB_VERSION ]]; then
    # Old ABI packages can disappear from rolling indices while remaining in
    # Ubuntu's official pool. Install all matching components together.
    install -d "$ROOT/debs"
    abi=${KERNEL%-generic}
    for package in "linux-headers-$abi" "linux-headers-$KERNEL" \
                   "linux-modules-$KERNEL" "${kernel_support[@]}" "linux-image-$KERNEL"; do
      architecture=amd64
      [[ $package == "linux-headers-$abi" ]] && architecture=all
      source=linux
      [[ $package == linux-image-* ]] && source=linux-signed
      file=${package}_${DEB_VERSION}_${architecture}.deb
      curl --noproxy '*' -fL --retry 3 --connect-timeout 15 --max-time 1800 --speed-limit 1024 --speed-time 60 \
        "${APT_MIRROR:-https://archive.ubuntu.com/ubuntu}/pool/main/l/$source/$file" -o "$ROOT/debs/$file"
    done
    apt-get "${apt_args[@]}" install -y "$ROOT"/debs/*.deb
  else
    apt-get "${apt_args[@]}" install -y "$KERNEL_PACKAGE" "$HEADERS_PACKAGE" "${kernel_support[@]}"
  fi
  install -d /etc/default/grub.d
  printf 'GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux %s"\nGRUB_CMDLINE_LINUX_DEFAULT="nokaslr console=ttyS0,115200n8"\n' \
    "$KERNEL" > /etc/default/grub.d/99-pvm-factory.cfg
  update-grub
  apt-mark hold "$KERNEL_PACKAGE" "$HEADERS_PACKAGE"
else
  read -r -a compiler_packages <<< "$COMPILER_PACKAGES"
  kernel_packages=("$KERNEL_PACKAGE" "$HEADERS_PACKAGE")
  [[ -z $KERNEL_RPMS ]] || read -r -a kernel_packages <<< "$KERNEL_RPMS"
  curl_packages=()
  command -v curl >/dev/null 2>&1 || curl_packages=(curl)
  dnf install -y "${compiler_packages[@]}" make rpm-build dwarves elfutils-libelf-devel elfutils-devel \
    zlib-devel openssl-devel pkgconf-pkg-config flex bison bc python3 "${curl_packages[@]}" dnsmasq \
    iproute iptables nftables libaio nvme-cli xfsprogs jq rsync git file kmod grubby "${extras[@]}" \
    "${kernel_packages[@]}"
  grubby --set-default "/boot/vmlinuz-$KERNEL"
  grubby --update-kernel "/boot/vmlinuz-$KERNEL" --args='nokaslr console=ttyS0,115200n8'
fi
[[ -d $BUILD ]] || { echo 'matching kernel headers missing' >&2; exit 1; }
# Cube starts its own scoped DNS process; the distribution-wide daemon would
# compete with systemd-resolved on Ubuntu.
systemctl disable --now dnsmasq.service 2>/dev/null || true
systemctl reset-failed dnsmasq.service 2>/dev/null || true
install -d /build
device=/dev/disk/by-id/virtio-pvm-shared
[[ -b $device ]] || { echo 'shared disk missing' >&2; exit 1; }
blkid "$device" >/dev/null # A runtime disk is never formatted by this workflow.
grep -q ' /build ' /etc/fstab || echo "$device /build ext4 defaults 0 2" >> /etc/fstab
mountpoint -q /build || mount /build

install -d /usr/local/libexec/pvm
if [[ -x $BUILD/tools/bpf/resolve_btfids/resolve_btfids ]]; then
  install -m0755 "$BUILD/tools/bpf/resolve_btfids/resolve_btfids" /usr/local/libexec/pvm/resolve_btfids
else
  tool=$ROOT/source/btf-source/tools/bpf/resolve_btfids
  make -C "$tool" CC="$CC" -j"$JOBS"
  install -m0755 "$tool/resolve_btfids" /usr/local/libexec/pvm/resolve_btfids
fi
if [[ -d $ROOT/dns ]]; then
  install -m0755 "$ROOT"/dns/*.sh /build/pvm-shared/runtime/cubesandbox/scripts/systemd/
fi

# Persist labels on this VM's overlay; the immutable backing disk is unchanged.
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  dnf install -y policycoreutils-python-utils container-selinux
  set_context() {
    semanage fcontext -a -t "$1" "$2" || semanage fcontext -m -t "$1" "$2"
  }
  set_context usr_t '/build(/.*)?'
  set_context bin_t '/build/pvm-shared/runtime/common/bin(/.*)?'
  set_context bin_t '/build/pvm-shared/runtime/cubesandbox/scripts(/.*)?'
  set_context bin_t '/build/pvm-shared/runtime/cubesandbox/(Cubelet|cube-egress|cube-shim|CubeS3lvol|coredns)(/.*)?'
  set_context bin_t '/build/pvm-shared/runtime/kata/(bin|runtime-rs-[^/]+/bin|libexec)(/.*)?'
  for name in docker containerd; do
    semanage fcontext -a -e "/var/lib/$name" "/build/pvm-shared/state/$name" ||
      semanage fcontext -m -e "/var/lib/$name" "/build/pvm-shared/state/$name"
  done
  restorecon /build /build/pvm-shared
  restorecon -RFx /build/pvm-shared/runtime
  restorecon -RF /build/pvm-shared/state/docker /build/pvm-shared/state/containerd
fi
INSTALL_PACKAGES=0 START_SERVICES=0 bash "$CONTEXT/scripts/attach-shared-runtime.sh"
install -d /etc/kata-containers/pvm
for hv in qemu dragonball clh; do
  install -m0644 "/opt/kata/share/defaults/kata-containers/runtime-rs-4.2.0/configuration-$hv-pvm.toml" \
    "/etc/kata-containers/pvm/configuration-$hv-pvm.toml"
done
systemctl daemon-reload
if [[ $FAMILY == ubuntu ]]; then
  apt-get clean
  rm -rf "$ROOT/debs"
fi
echo PVM_IMAGE_PROVISIONED=1
