#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/bin:/usr/local/sbin:$PATH

mode="${1:-run}"
id="${2:-pvm-oot-test}"
bundle="/tmp/kata-pvm-bundle-$id"
log="/tmp/kata-pvm-runtime-$id.log"
kata_config="/tmp/kata-pvm-configuration-$id.toml"
busybox="${BUSYBOX_PATH:-$(command -v busybox || true)}"
ctr="${CTR_PATH:-$(command -v ctr || true)}"
[[ -x $busybox && -x $ctr ]] || {
	echo 'Kata test requires executable busybox and ctr (or BUSYBOX_PATH/CTR_PATH)' >&2
	exit 2
}
kata_config_source="${KATA_CONFIG_SOURCE:-/etc/kata-containers/configuration.toml}"
kata_runtime="${KATA_RUNTIME:-io.containerd.kata.v2}"
qboot="${QBOOT_PATH:-/usr/share/qemu/qboot.rom}"
configure_qboot="${KATA_CONFIGURE_QBOOT:-1}"
qemu_machine="${KATA_QEMU_MACHINE:-q35}"
use_runtime_config_path="${KATA_USE_RUNTIME_CONFIG_PATH:-1}"

cleanup() {
	sudo "$ctr" tasks kill --signal SIGKILL "$id" >/dev/null 2>&1 || true
	sudo "$ctr" containers rm "$id" >/dev/null 2>&1 || true
	sudo rm -rf "$bundle" \
		"/run/kata-containers/$id" \
		"/run/vc/sbs/$id" \
		"/run/vc/vm/$id"
	sudo rm -f "$log" "$kata_config"
}

if [[ ! -f "$kata_config_source" ]]; then
	kata_config_source=/opt/kata/share/defaults/kata-containers/configuration.toml
fi
if [[ ! -f "$qboot" ]]; then
	qboot=/opt/kata/share/kata-qemu/qemu/qboot.rom
fi

sudo rm -rf "$bundle" \
	"/run/kata-containers/$id" \
	"/run/vc/sbs/$id" \
	"/run/vc/vm/$id"

mkdir -p "$bundle/rootfs/bin" "$bundle/rootfs/proc" "$bundle/rootfs/sys" \
	"$bundle/rootfs/dev" "$bundle/rootfs/tmp"
cp "$busybox" "$bundle/rootfs/bin/busybox"
ln -sf busybox "$bundle/rootfs/bin/sh"
ln -sf busybox "$bundle/rootfs/bin/uname"

cd "$bundle"
runc spec
python3 - <<'PY'
import json

path = "config.json"
with open(path, encoding="utf-8") as source:
    config = json.load(source)
config["process"]["terminal"] = False
config["process"]["args"] = [
    "/bin/sh",
    "-c",
    'echo kata-pvm-oot-ok; uname -a; grep -m1 "address sizes" /proc/cpuinfo || true',
]
config["root"]["readonly"] = False
config["linux"]["namespaces"] = [
    namespace
    for namespace in config["linux"]["namespaces"]
    if namespace["type"] != "network"
]
with open(path, "w", encoding="utf-8") as destination:
    json.dump(config, destination, separators=(",", ":"))
PY

if [ "$mode" = "prepare-only" ]; then
	exit 0
fi

trap cleanup EXIT
sudo rm -f "$log"
cp "$kata_config_source" "$kata_config"
if [[ "$configure_qboot" == 1 ]]; then
	[[ -f "$qboot" ]] || { echo "qboot firmware not found: $qboot" >&2; exit 1; }
	sed -i "s/^machine_type = .*/machine_type = \"$qemu_machine\"/" "$kata_config"
	sed -i "s|^firmware = .*|firmware = \"$qboot\"|" "$kata_config"
fi
sudo "$ctr" c rm "$id" 2>/dev/null || true
runtime_options=(--runtime "$kata_runtime")
if [[ "$use_runtime_config_path" == 1 ]]; then
	runtime_options+=(--runtime-config-path "$kata_config")
fi
sudo "$ctr" run --rm "${runtime_options[@]}" --rootfs \
	"$bundle/rootfs" "$id" /bin/sh -c \
	'echo kata-pvm-ctr-ok; uname -a; grep -m1 "address sizes" /proc/cpuinfo || true'
