#!/usr/bin/env bash
set -euo pipefail

ARCHIVE=${1:-}
VERSION=${2:-}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Firecracker archive not found: $ARCHIVE" >&2; exit 2; }
[[ -n "$VERSION" ]] || { echo "Firecracker version is required" >&2; exit 2; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
tar -C "$stage" -xzf "$ARCHIVE"
binary=$(find "$stage" -type f -name "firecracker-v${VERSION}-x86_64" -print -quit)
[[ -n "$binary" ]] || {
  echo "Firecracker v$VERSION binary is missing from archive" >&2
  exit 1
}

install -m 0755 "$binary" /usr/local/bin/firecracker
/usr/local/bin/firecracker --version | grep -F "v$VERSION"
