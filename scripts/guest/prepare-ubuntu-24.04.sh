#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive

apt-get update
packages=(
  bc bison build-essential busybox-static containerd curl dwarves file flex
  git jq kmod libelf-dev libssl-dev linux-headers-generic
  cpio pkg-config python3 rpm2cpio rsync tar xz-utils zstd
)
apt-get install -y "${packages[@]}"

systemctl enable --now containerd
mkdir -p /build/pvm/{artifacts,build,cache,logs,src}

if [[ ${INSTALL_HWE:-0} == 1 ]]; then
  apt-get install -y linux-generic-hwe-24.04 linux-headers-generic-hwe-24.04
fi

printf 'os=%s\nkernel=%s\n' "$(. /etc/os-release; echo "$PRETTY_NAME")" "$(uname -r)" > /build/pvm/artifacts/guest-environment.txt
