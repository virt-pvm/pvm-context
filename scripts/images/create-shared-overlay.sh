#!/usr/bin/env bash
set -euo pipefail

BASE=${1:?usage: create-shared-overlay.sh BASE OVERLAY}
OVERLAY=${2:?usage: create-shared-overlay.sh BASE OVERLAY}
QEMU_IMG_BIN=${QEMU_IMG_BIN:-qemu-img}

command -v "$QEMU_IMG_BIN" >/dev/null || {
  echo "qemu-img not found: $QEMU_IMG_BIN" >&2
  exit 2
}
[[ -f "$BASE" ]] || { echo "shared base not found: $BASE" >&2; exit 2; }

BASE=$(realpath "$BASE")
OVERLAY=$(realpath -m "$OVERLAY")
[[ "$BASE" != "$OVERLAY" ]] || { echo "base and overlay must differ" >&2; exit 2; }
mkdir -p "$(dirname "$OVERLAY")"

if [[ -e "$OVERLAY" ]]; then
  actual=$(
    "$QEMU_IMG_BIN" info --output=json "$OVERLAY" |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("full-backing-filename", ""))'
  )
  [[ "$actual" == "$BASE" ]] || {
    echo "overlay backing mismatch: $OVERLAY" >&2
    echo "expected: $BASE" >&2
    echo "actual:   ${actual:-<none>}" >&2
    exit 1
  }
else
  "$QEMU_IMG_BIN" create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY"
fi

# Every VM writes only its own overlay. The common base must never be opened
# writable while overlays depend on it.
chmod a-w "$BASE"
"$QEMU_IMG_BIN" check "$OVERLAY"
printf 'PVM_SHARED_BASE=%s\nPVM_SHARED_OVERLAY=%s\n' "$BASE" "$OVERLAY"
