#!/usr/bin/env bash
set -euo pipefail

SHARED_MOUNT="${SHARED_MOUNT:-/build}"
SHARED_ROOT="${SHARED_ROOT:-$SHARED_MOUNT/pvm-shared}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
START_SERVICES="${START_SERVICES:-1}"

[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 2; }

without_proxy() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u ALL_PROXY -u NO_PROXY "$@"
}

install_support_packages() {
  [[ "$INSTALL_PACKAGES" == 1 ]] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    without_proxy apt-get update
    without_proxy env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl dnsmasq iproute2 iptables libaio1t64 nvme-cli python3 xfsprogs
  elif command -v dnf >/dev/null 2>&1; then
    local -a packages=(dnsmasq iproute iptables nftables nvme-cli python3 xfsprogs)
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    if [[ "$(. /etc/os-release; printf '%s' "$ID")" == amzn ]]; then
      packages+=(python3.11 runc)
    fi
    without_proxy dnf install -y "${packages[@]}"
  else
    echo "unsupported package manager; set INSTALL_PACKAGES=0 after installing dependencies" >&2
    exit 2
  fi
}

install_support_packages

# Ubuntu's time64 transition renamed the x86_64 libaio SONAME even though its
# ABI is unchanged. CubeS3lvol is built against the pre-transition SONAME.
if ! ldconfig -p | grep -q 'libaio\.so\.1 ' && \
   [[ -e /usr/lib/x86_64-linux-gnu/libaio.so.1t64 ]]; then
  ln -sfn libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
fi

install -d -m 0755 "$SHARED_MOUNT"
mountpoint -q "$SHARED_MOUNT" || mount "$SHARED_MOUNT"

COMMON="$SHARED_ROOT/runtime/common/bin"
KATA="$SHARED_ROOT/runtime/kata"
CUBE="$SHARED_ROOT/runtime/cubesandbox"
CUBECOW="$SHARED_ROOT/cubesandbox/cubelet-cubecow.xfs"
for path in "$COMMON/containerd" "$COMMON/ctr" "$COMMON/runc" \
  "$COMMON/dockerd" "$KATA" "$CUBE" "$CUBECOW"; do
  [[ -e "$path" ]] || { echo "missing shared runtime asset: $path" >&2; exit 1; }
done
# Check native library dependencies before enabling an endlessly restarting unit.
"$COMMON/dockerd" --version
"$COMMON/containerd" --version

primary_iface=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
primary_ip=$(ip -4 -o addr show dev "$primary_iface" scope global |
  awk 'NR == 1 { split($4, address, "/"); print address[1] }')
[[ -n "$primary_iface" && -n "$primary_ip" ]] || {
  echo "cannot determine CubeSandbox host interface/address" >&2
  exit 1
}
cube_env="$CUBE/.one-click.env"
cubelet_config="$CUBE/Cubelet/config/config.toml"
[[ -f "$cube_env" && -f "$cubelet_config" ]] || {
  echo "CubeSandbox network configuration is missing" >&2
  exit 1
}
# Resolve the CA worker group through NSS as well as by numeric ownership.
# Some distribution install(1) implementations require a named group entry.
worker_gid=$(bash -c 'source "$1"; printf "%s" "${CUBE_EGRESS_WORKER_GID:-8049}"' bash "$cube_env")
[[ $worker_gid =~ ^[0-9]+$ ]] || { echo "invalid CubeEgress worker GID" >&2; exit 2; }
if ! getent group "$worker_gid" >/dev/null; then
  groupadd --gid "$worker_gid" "cube-egress-ca-$worker_gid"
fi
sed -i \
  -e "s/^CUBE_SANDBOX_NODE_IP=.*/CUBE_SANDBOX_NODE_IP=$primary_ip/" \
  -e "s/^CUBE_SANDBOX_ETH_NAME=.*/CUBE_SANDBOX_ETH_NAME=$primary_iface/" \
  "$cube_env"
sed -i -E \
  "/^[[:space:]]*\[plugins\.\"io\.cubelet\.internal\.v1\.network\"\]/,/^[[:space:]]*\[/ s/^([[:space:]]*eth_name[[:space:]]*=[[:space:]]*).*/\1\"$primary_iface\"/" \
  "$cubelet_config"

install -d -m 0755 /usr/local/bin /usr/local/sbin /usr/local/services
for name in containerd ctr runc busybox dockerd docker docker-compose \
  containerd-shim-runc-v2; do
  [[ -e "$COMMON/$name" ]] || continue
  ln -sfn "$COMMON/$name" "/usr/local/bin/$name"
done
if [[ "$(. /etc/os-release; printf '%s' "$ID")" == amzn ]]; then
  ln -sfn /usr/sbin/runc /usr/local/bin/runc
fi
if [[ ! -L /opt/kata || "$(readlink -f /opt/kata)" != "$(readlink -f "$KATA")" ]]; then
  rm -rf /opt/kata
  ln -s "$KATA" /opt/kata
fi
install -d -m 0755 /etc/kata-containers
ln -sfn /opt/kata/share/defaults/kata-containers/runtime-rs-4.2.0 \
  /etc/kata-containers/runtime-rs-4.2.0
ln -sfn /opt/kata/runtime-rs-4.2.0/bin/containerd-shim-kata-v2 \
  /usr/local/bin/containerd-shim-kata-v2
ln -sfn /opt/kata/runtime-rs-4.2.0/bin/containerd-shim-kata-v2 \
  /usr/local/bin/containerd-shim-kata-rs420-v2
rm -rf /usr/local/services/cubetoolbox
ln -s "$CUBE" /usr/local/services/cubetoolbox
ln -sfn "$CUBE/cube-shim/bin/containerd-shim-cube-rs" \
  /usr/local/bin/containerd-shim-cube-rs
ln -sfn "$CUBE/cube-shim/bin/cube-runtime" /usr/local/bin/cube-runtime

install -m 0644 "$SHARED_ROOT/runtime/systemd/containerd-shared.service" \
  /etc/systemd/system/containerd.service
install -m 0644 "$SHARED_ROOT/runtime/systemd/docker-shared.service" \
  /etc/systemd/system/docker.service

install -d -m 0711 "$SHARED_ROOT/state/docker" "$SHARED_ROOT/state/containerd"
install -d -m 0755 /data/cubelet /data/cube-shim /data/snapshot_pack /data/log
cube_fstab="$CUBECOW /data/cubelet xfs loop,nofail,x-systemd.requires-mounts-for=$SHARED_MOUNT 0 0"
if ! grep -qF "$CUBECOW /data/cubelet " /etc/fstab; then
  printf '%s\n' "$cube_fstab" >> /etc/fstab
fi
mountpoint -q /data/cubelet || mount /data/cubelet

"$CUBE/scripts/systemd/install-units.sh"
install -d -m 0755 /etc/systemd/system/cube-sandbox-s3lvol.service.d
cat > /etc/systemd/system/cube-sandbox-s3lvol.service.d/10-docker-order.conf <<'EOF'
[Unit]
# Keep the local object store available until S3lvol has stopped.
After=docker.service cube-sandbox-minio.service
EOF
install -d -m 0755 /etc/systemd/system/cube-sandbox-cubelet.service.d
cat > /etc/systemd/system/cube-sandbox-cubelet.service.d/10-s3lvol.conf <<'EOF'
[Unit]
Requires=cube-sandbox-s3lvol.service
After=cube-sandbox-s3lvol.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 180); do test -S /var/run/s3lvol.sock && exit 0; systemctl is-failed --quiet cube-sandbox-s3lvol.service && exit 1; sleep 1; done; exit 1'
EOF
ln -sfn "$SHARED_ROOT/scripts/pvm-test.sh" /usr/local/sbin/pvm-test
ln -sfn "$SHARED_ROOT/scripts/kata-pvm-test-all.sh" /usr/local/sbin/kata-pvm-test-all
ln -sfn "$SHARED_ROOT/scripts/cubesandbox-pvm-test.sh" /usr/local/sbin/cubesandbox-pvm-test

systemctl daemon-reload
systemctl enable containerd.service docker.service cube-sandbox-s3lvol.service \
  cube-sandbox-control.target
systemctl stop cube-sandbox-control.target cube-sandbox-compute.target \
  cube-sandbox-cubelet.service cube-sandbox-s3lvol.service 2>/dev/null || true
systemctl stop docker.service containerd.service 2>/dev/null || true
pkill -TERM -x dockerd 2>/dev/null || true
pkill -TERM -x containerd 2>/dev/null || true
for _ in $(seq 1 20); do
  if ! pgrep -x dockerd >/dev/null && ! pgrep -x containerd >/dev/null; then
    break
  fi
  sleep 1
done
if pgrep -x dockerd >/dev/null || pgrep -x containerd >/dev/null; then
  echo "old docker/containerd processes did not stop" >&2
  exit 1
fi
if [[ "$START_SERVICES" == 1 ]]; then
  systemctl start containerd.service docker.service
  systemctl start --no-block cube-sandbox-control.target
  for _ in $(seq 1 180); do
    if [[ -S /var/run/s3lvol.sock && -s /etc/cube/ca/cube-root-ca.crt ]] && \
       systemctl is-active --quiet cube-sandbox-cubelet.service && \
       systemctl is-active --quiet cube-sandbox-cube-egress.service; then
      break
    fi
    if systemctl is-failed --quiet cube-sandbox-s3lvol.service || \
       systemctl is-failed --quiet cube-sandbox-cubelet.service; then
      systemctl --no-pager --full status cube-sandbox-s3lvol.service \
        cube-sandbox-cubelet.service >&2 || true
      exit 1
    fi
    sleep 1
  done
  [[ -S /var/run/s3lvol.sock && -s /etc/cube/ca/cube-root-ca.crt ]] && \
    systemctl is-active --quiet cube-sandbox-cubelet.service && \
    systemctl is-active --quiet cube-sandbox-cube-egress.service || {
      echo "CubeSandbox data plane did not become ready" >&2
      exit 1
    }
fi
echo "shared PVM runtime attached at $SHARED_ROOT"
