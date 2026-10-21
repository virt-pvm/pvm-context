#!/usr/bin/env bash
set -euo pipefail

KERNEL=${PVM_GUEST_KERNEL:-/opt/kata/share/kata-containers/vmlinux.pvm}
SOURCE_DIR=${KATA_DEFAULTS_DIR:-/opt/kata/share/defaults/kata-containers}
OUTPUT_DIR=${KATA_CONFIG_DIR:-/etc/kata-containers/pvm}
RUND_ROOT=${RUND_ROOT:-/usr/local/share/kangaroo/current}
DEFAULT_IMAGE=/opt/kata/share/kata-containers/kata-containers.img
[[ -f "$DEFAULT_IMAGE" ]] || DEFAULT_IMAGE=/opt/kata/share/kata-containers/kata-ubuntu-noble.image
IMAGE=${PVM_GUEST_IMAGE:-$DEFAULT_IMAGE}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -f "$KERNEL" ]] || { echo "guest kernel not found: $KERNEL" >&2; exit 2; }
[[ -f "$IMAGE" ]] || { echo "guest image not found: $IMAGE" >&2; exit 2; }

if [[ -f "$SOURCE_DIR/runtime-rs/configuration-qemu-runtime-rs.toml" ]]; then
  config_kind=runtime-rs
  qemu_source="$SOURCE_DIR/runtime-rs/configuration-qemu-runtime-rs.toml"
  clh_source="$SOURCE_DIR/runtime-rs/configuration-clh-runtime-rs.toml"
  dragonball_source="$SOURCE_DIR/runtime-rs/configuration-dragonball.toml"
elif [[ -f "$OUTPUT_DIR/configuration-qemu-pvm.toml" &&
        -f "$OUTPUT_DIR/configuration-clh-pvm.toml" &&
        -f "$OUTPUT_DIR/configuration-dragonball-pvm.toml" ]]; then
  # A size-trimmed shared runtime may intentionally omit upstream example
  # configs. Reuse the previously generated runtime-rs configs in that case.
  config_kind=runtime-rs
  qemu_source="$OUTPUT_DIR/configuration-qemu-pvm.toml"
  clh_source="$OUTPUT_DIR/configuration-clh-pvm.toml"
  dragonball_source="$OUTPUT_DIR/configuration-dragonball-pvm.toml"
else
  config_kind=legacy
  qemu_source="$SOURCE_DIR/configuration-qemu.toml"
  clh_source="$SOURCE_DIR/configuration-clh.toml"
  dragonball_source="$RUND_ROOT/kata-containers2/configuration.toml.asi.csk.pvm"
fi
for file in "$qemu_source" "$clh_source" "$dragonball_source"; do
  [[ -f "$file" ]] || { echo "Kata config not found: $file" >&2; exit 2; }
done

install -d -m 0755 "$OUTPUT_DIR"
[[ "$qemu_source" == "$OUTPUT_DIR/configuration-qemu-pvm.toml" ]] ||
  install -m 0644 "$qemu_source" "$OUTPUT_DIR/configuration-qemu-pvm.toml"
[[ "$clh_source" == "$OUTPUT_DIR/configuration-clh-pvm.toml" ]] ||
  install -m 0644 "$clh_source" "$OUTPUT_DIR/configuration-clh-pvm.toml"
[[ "$dragonball_source" == "$OUTPUT_DIR/configuration-dragonball-pvm.toml" ]] ||
  install -m 0644 "$dragonball_source" "$OUTPUT_DIR/configuration-dragonball-pvm.toml"

python3 - "$OUTPUT_DIR" "$KERNEL" "$IMAGE" "$config_kind" <<'PY'
from pathlib import Path
import sys

directory = Path(sys.argv[1])
kernel = sys.argv[2]
image = sys.argv[3]
config_kind = sys.argv[4]

def replace_values(path, values):
    lines = path.read_text(encoding="utf-8").splitlines()
    found = set()
    output = []
    for line in lines:
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
        if key in values:
            value = values[key]
            rendered = value[1] if isinstance(value, tuple) else f'"{value}"'
            output.append(f'{indent}{key} = {rendered}')
            found.add(key)
        else:
            output.append(line)
    missing = set(values) - found
    if missing:
        raise SystemExit(f"{path}: missing keys: {', '.join(sorted(missing))}")
    path.write_text("\n".join(output) + "\n", encoding="utf-8")

def replace_array(path, key, values):
    lines = path.read_text(encoding="utf-8").splitlines()
    output = []
    replacing = False
    found = False
    for line in lines:
        stripped = line.strip()
        if not replacing and stripped.startswith(f"{key} = ["):
            found = True
            replacing = True
            output.append(f"{key} = [")
            output.extend(f'    "{value}",' for value in values)
            if stripped.endswith("]"):
                replacing = False
                output.append("]")
            continue
        if replacing:
            if stripped == "]":
                replacing = False
                output.append("]")
            continue
        output.append(line)
    if replacing or not found:
        raise SystemExit(f"{path}: malformed or missing {key}")
    path.write_text("\n".join(output) + "\n", encoding="utf-8")

common = {"kernel": kernel, "image": image}
replace_values(directory / "configuration-clh-pvm.toml", common)
if config_kind == "runtime-rs":
    replace_values(directory / "configuration-qemu-pvm.toml", {
        **common,
        "firmware": "/opt/kata/share/kata-qemu/qemu/qboot.rom",
        "machine_type": "q35",
        "block_device_driver": "virtio-blk-pci",
        "vm_rootfs_driver": "virtio-blk-pci",
    })
    replace_values(directory / "configuration-dragonball-pvm.toml", {
        **common,
        "kernel_params": "console=ttyS1 agent.log_vport=1025 agent.hotplug_timeout=30 vsyscall=emulate",
    })
else:
    replace_values(directory / "configuration-qemu-pvm.toml", {
        **common,
        "firmware": "/opt/kata/share/kata-qemu/qemu/qboot.rom",
        "machine_type": "q35",
        "block_device_driver": "virtio-blk",
        "shared_fs": "virtio-9p",
    })
    replace_values(directory / "configuration-dragonball-pvm.toml", {
        **common,
        "default_vcpus": ("raw", "1"),
        "default_maxvcpus": ("raw", "2"),
        "default_memory": ("raw", "2048"),
        "vm_rootfs_driver": "virtio-blk",
        "enable_tracing": ("raw", "false"),
        "enable_remote_disk": ("raw", "false"),
        "enable_cpu_hotplug": ("raw", "false"),
        "phyaddr_size_bit": ("raw", "43"),
        "sandbox_packages": ("raw", "[]"),
    })
    replace_array(directory / "configuration-dragonball-pvm.toml", "kernel_params", [
        "console=ttyS1",
        "agent.log_vport=1025",
        "agent.hotplug_timeout=30",
        "vsyscall=emulate",
    ])
PY

if [[ "$config_kind" == legacy ]]; then
  # Rund resolves its default config relative to its own versioned executable.
  install -m 0644 "$OUTPUT_DIR/configuration-dragonball-pvm.toml" \
    "$RUND_ROOT/kata-containers2/configuration.toml"
fi

echo "config_kind=$config_kind"
grep -H -E '^(kernel|image|firmware|machine_type) =' "$OUTPUT_DIR"/*.toml
