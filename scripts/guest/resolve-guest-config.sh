#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/pins/guest-config.env"

OUTPUT=${1:?usage: resolve-guest-config.sh <output> [local-override]}
OVERRIDE=${2:-}
install -d -m 0755 "$(dirname -- "$OUTPUT")"
tmp=$(mktemp "${OUTPUT}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

if [[ -n "$OVERRIDE" ]]; then
  [[ -f "$OVERRIDE" ]] || { echo "guest config override not found: $OVERRIDE" >&2; exit 2; }
  cp -- "$OVERRIDE" "$tmp"
  source_id="override:$OVERRIDE"
elif [[ -n "${PVM_GUEST_CONFIG_REPO_DIR:-}" ]]; then
  git -C "$PVM_GUEST_CONFIG_REPO_DIR" cat-file -e \
    "$PVM_GUEST_CONFIG_COMMIT:$PVM_GUEST_CONFIG_PATH"
  git -C "$PVM_GUEST_CONFIG_REPO_DIR" show \
    "$PVM_GUEST_CONFIG_COMMIT:$PVM_GUEST_CONFIG_PATH" > "$tmp"
  source_id="repo:$PVM_GUEST_CONFIG_COMMIT:$PVM_GUEST_CONFIG_PATH"
else
  url="${PVM_GUEST_CONFIG_REPO%.git}/raw/$PVM_GUEST_CONFIG_COMMIT/$PVM_GUEST_CONFIG_PATH"
  curl -fL --retry 3 --output "$tmp" "$url"
  source_id="repo:$PVM_GUEST_CONFIG_COMMIT:$PVM_GUEST_CONFIG_PATH"
fi

if [[ -z "$OVERRIDE" ]]; then
  printf '%s  %s\n' "$PVM_GUEST_CONFIG_SHA256" "$tmp" | sha256sum -c - >/dev/null
fi
install -m 0644 "$tmp" "$OUTPUT"
printf '%s  %s\n' "$(sha256sum "$OUTPUT" | awk '{print $1}')" "$(basename -- "$OUTPUT")" \
  > "$OUTPUT.sha256"
printf '%s\n' "$source_id" > "$OUTPUT.source"
