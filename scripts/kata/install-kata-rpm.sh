#!/usr/bin/env bash
set -euo pipefail

RUNTIME_RPM=${1:-}
OPENSSL_RPM=${2:-}
OPENSSL_DIR=${KANGAROO_OPENSSL11_DIR:-/usr/local/lib/kangaroo-openssl11}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -f "$RUNTIME_RPM" ]] || { echo "runtime RPM not found: $RUNTIME_RPM" >&2; exit 2; }
[[ -f "$OPENSSL_RPM" ]] || { echo "OpenSSL compatibility RPM not found: $OPENSSL_RPM" >&2; exit 2; }
command -v rpm2cpio >/dev/null
command -v cpio >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/runtime" "$work/openssl"
(
  cd "$work/runtime"
  rpm2cpio "$RUNTIME_RPM" | cpio -idm --quiet --no-preserve-owner
)
(
  cd "$work/openssl"
  rpm2cpio "$OPENSSL_RPM" | cpio -idm --quiet --no-preserve-owner
)

release_dir=$(find "$work/runtime/usr/local/share/kangaroo" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n1)
[[ -n "$release_dir" ]] || { echo "cannot identify Kangaroo release directory" >&2; exit 1; }
runtime_root="/usr/local/share/kangaroo/$release_dir"

mkdir -p /usr/local/share/kangaroo "$OPENSSL_DIR" /usr/local/bin
cp -a "$work/runtime/usr/local/share/kangaroo/$release_dir" /usr/local/share/kangaroo/
find "$work/openssl" -type f \( -name 'libssl.so.1.1*' -o -name 'libcrypto.so.1.1*' \) -exec cp -a {} "$OPENSSL_DIR/" \;
find "$work/openssl" -type l \( -name 'libssl.so.1.1*' -o -name 'libcrypto.so.1.1*' \) -exec cp -a {} "$OPENSSL_DIR/" \;

[[ -e "$OPENSSL_DIR/libssl.so.1.1" ]]
[[ -e "$OPENSSL_DIR/libcrypto.so.1.1" ]]
ln -sfn "$release_dir" /usr/local/share/kangaroo/current

cat > /usr/local/bin/containerd-shim-rund-v2 <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$OPENSSL_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$runtime_root/bin/containerd-shim-rund-v2" "\$@"
EOF
chmod 0755 /usr/local/bin/containerd-shim-rund-v2

cat > /usr/local/bin/containerd-shim-rund-v2-cli <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$OPENSSL_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$runtime_root/bin/containerd-shim-rund-v2-cli" "\$@"
EOF
chmod 0755 /usr/local/bin/containerd-shim-rund-v2-cli

/usr/local/bin/containerd-shim-rund-v2 --version
systemctl restart containerd
