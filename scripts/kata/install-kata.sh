#!/usr/bin/env bash
set -euo pipefail

ARCHIVE=${1:-}
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Kata archive not found: $ARCHIVE" >&2; exit 2; }

stage=$(mktemp -d /opt/kata-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
tar -C "$stage" -xaf "$ARCHIVE"
[[ -d "$stage/opt/kata" ]] || { echo "archive does not contain /opt/kata" >&2; exit 1; }

# Some static release archives ship helper binaries as 0744. Normalize the
# executables that may be launched after dropping root privileges.
for executable in \
  bin/cloud-hypervisor \
  bin/openvmm \
  libexec/nydusd \
  libexec/virtiofsd; do
  if [[ -f "$stage/opt/kata/$executable" ]]; then
    chmod 0755 "$stage/opt/kata/$executable"
  fi
done

if [[ -x "$stage/opt/kata/runtime-rs/bin/containerd-shim-kata-v2" ]]; then
  shim=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
elif [[ -x "$stage/opt/kata/bin/containerd-shim-kata-v2" ]]; then
  shim=/opt/kata/bin/containerd-shim-kata-v2
else
  echo "Kata shim is missing from archive" >&2
  exit 1
fi

rm -rf /opt/kata.previous
if [[ -d /opt/kata ]]; then
  mv /opt/kata /opt/kata.previous
fi
mv "$stage/opt/kata" /opt/kata
ln -sfn "$shim" /usr/local/bin/containerd-shim-kata-v2
if [[ -x /opt/kata/bin/kata-runtime ]]; then
  ln -sfn /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
else
  rm -f /usr/local/bin/kata-runtime
fi
if [[ -x /opt/kata/bin/kata-collect-data.sh ]]; then
  ln -sfn /opt/kata/bin/kata-collect-data.sh /usr/local/bin/kata-collect-data.sh
else
  rm -f /usr/local/bin/kata-collect-data.sh
fi
systemctl restart containerd
cat /opt/kata/VERSION
"$shim" --version
