#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-$SCRIPT_DIR/firecracker-pvm.json}
FIRECRACKER=${FIRECRACKER:-}
FIRECRACKER_LOG=${FIRECRACKER_LOG:-/tmp/firecracker-pvm.log}
FIRECRACKER_TIMEOUT=${FIRECRACKER_TIMEOUT:-30}
PVM_MODULE=${PVM_MODULE:-}
PVM_ROOTFS=${PVM_ROOTFS:-}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable" >&2; exit 1; }
if [[ -z "$FIRECRACKER" ]]; then
  for candidate in \
    /usr/local/bin/firecracker \
    /opt/kata/bin/firecracker; do
    if [[ -x "$candidate" ]]; then
      FIRECRACKER=$candidate
      break
    fi
  done
fi
[[ -x "$FIRECRACKER" ]] || { echo "firecracker not found: $FIRECRACKER" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG" >&2; exit 1; }

runtime_config=$(mktemp --tmpdir firecracker-pvm.XXXXXX.json)
trap 'rm -f "$runtime_config"' EXIT
python3 - "$CONFIG" "$runtime_config" "$PVM_ROOTFS" <<'PY'
import glob
import json
import os
import sys

source, destination, override = sys.argv[1:]
with open(source, encoding="utf-8") as stream:
    config = json.load(stream)

drives = config.get("drives", [])
if not drives:
    raise SystemExit(f"no drives configured in {source}")

configured = override or drives[0].get("path_on_host", "")
if configured and os.path.isfile(configured):
    rootfs = configured
else:
    search_dir = os.path.dirname(configured) or "/opt/kata/share/kata-containers"
    candidates = sorted(glob.glob(os.path.join(search_dir, "kata-*.image")))
    if len(candidates) != 1:
        raise SystemExit(
            f"expected one Kata rootfs image in {search_dir}, found {len(candidates)}; "
            "set PVM_ROOTFS explicitly"
        )
    rootfs = candidates[0]

drives[0]["path_on_host"] = rootfs
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
    stream.write("\n")
print(f"firecracker_rootfs={rootfs}")
PY

if [[ -z "$PVM_MODULE" ]]; then
  for candidate in kvm_pvm kvm_amd; do
    if grep -q "^$candidate " /proc/modules; then
      PVM_MODULE=$candidate
      break
    fi
  done
fi
[[ -n "$PVM_MODULE" ]] || { echo "no PVM module is loaded" >&2; exit 1; }

module_path=$(modinfo -n "$PVM_MODULE")
[[ "$module_path" == /lib/modules/"$(uname -r)"/updates/pvm-oot/*.ko ]] || {
  echo "unexpected $PVM_MODULE module: $module_path" >&2
  exit 1
}

rm -f "$FIRECRACKER_LOG"
"$FIRECRACKER" --version
dmesg -C
set +e
timeout --signal=TERM --kill-after=5 "$FIRECRACKER_TIMEOUT" \
  "$FIRECRACKER" --no-api --config-file "$runtime_config" \
  >"$FIRECRACKER_LOG" 2>&1
firecracker_status=$?
set -e

cat "$FIRECRACKER_LOG"
grep -Eq 'Linux version .*pvm' "$FIRECRACKER_LOG" || {
  echo "PVM guest kernel did not start (firecracker status $firecracker_status)" >&2
  exit 1
}
grep -Eq 'Reached target .*kata-containers.target|ttRPC server started' "$FIRECRACKER_LOG" || {
  echo "kata-agent did not become ready (firecracker status $firecracker_status)" >&2
  exit 1
}

if dmesg | grep -Eqi 'refcount|WARNING:|BUG:|Oops|general protection|Call Trace'; then
  echo "host kernel reported an error during the Firecracker test" >&2
  dmesg >&2
  exit 1
fi

echo "FIRECRACKER_PVM_BOOT=PASS"
