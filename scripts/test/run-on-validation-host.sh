#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
ACTION=${1:-all}
PROFILE=${2:-"$ROOT_DIR/configs/ubuntu-24.04-basic.local.env"}

[[ -f "$PROFILE" ]] || { echo "profile not found: $PROFILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$PROFILE"
: "${PVM_VALIDATION_HOST:?set PVM_VALIDATION_HOST in the local profile}"
: "${PVM_REMOTE_ROOT:?set PVM_REMOTE_ROOT in the local profile}"

remote_profile="$PVM_REMOTE_ROOT/configs/ubuntu-24.04-basic.local.env"
ssh "$PVM_VALIDATION_HOST" "mkdir -p '$PVM_REMOTE_ROOT'"
rsync -a --delete \
  --exclude='.git/' --exclude='.artifacts/' --exclude='configs/*.local.env' \
  -e ssh "$ROOT_DIR/" "$PVM_VALIDATION_HOST:$PVM_REMOTE_ROOT/"
scp "$PROFILE" "$PVM_VALIDATION_HOST:$remote_profile"

if [[ -n "$PVM_CONTROL_KATA_ARCHIVE" ]]; then
  [[ -f "$PVM_CONTROL_KATA_ARCHIVE" ]] || {
    echo "Kata archive is invalid: $PVM_CONTROL_KATA_ARCHIVE" >&2
    exit 2
  }
  : "${KATA_ARCHIVE:?set remote KATA_ARCHIVE when PVM_CONTROL_KATA_ARCHIVE is used}"
  ssh "$PVM_VALIDATION_HOST" "mkdir -p '$(dirname "$KATA_ARCHIVE")'"
  rsync -a -e ssh "$PVM_CONTROL_KATA_ARCHIVE" "$PVM_VALIDATION_HOST:$KATA_ARCHIVE"
fi

stage_artifact() {
  local name=$1 source=$2 destination=$3
  [[ -n "$source" ]] || return 0
  [[ -f "$source" ]] || { echo "$name is invalid: $source" >&2; exit 2; }
  [[ -n "$destination" ]] || { echo "$name remote destination is not set" >&2; exit 2; }
  ssh "$PVM_VALIDATION_HOST" "mkdir -p '$(dirname "$destination")'"
  rsync -a -e ssh "$source" "$PVM_VALIDATION_HOST:$destination"
}

stage_artifact Firecracker "$PVM_CONTROL_FIRECRACKER_ARCHIVE" "$FIRECRACKER_ARCHIVE"

stage_source() {
  local name=$1 source=$2 destination=$3
  [[ -n "$source" ]] || return 0
  [[ -f "$source/Makefile" ]] || { echo "$name source is invalid: $source" >&2; exit 2; }
  [[ -n "$destination" ]] || { echo "$name remote destination is not set" >&2; exit 2; }
  ssh "$PVM_VALIDATION_HOST" "mkdir -p '$destination'"
  rsync -a --delete --exclude='.git/' -e ssh \
    "$source/" "$PVM_VALIDATION_HOST:$destination/"
}

stage_source 66-base "$PVM_CONTROL_66_BASE_SOURCE" "$PVM_66_BASE_SOURCE"
stage_source 612-base "$PVM_CONTROL_612_BASE_SOURCE" "$PVM_612_BASE_SOURCE"
stage_source 66-oot "$PVM_CONTROL_66_SOURCE_WORKTREE" "$PVM_66_SOURCE_WORKTREE"
stage_source 612-oot "$PVM_CONTROL_612_SOURCE_WORKTREE" "$PVM_612_SOURCE_WORKTREE"
stage_source guest "$PVM_CONTROL_GUEST_SOURCE_WORKTREE" "$PVM_GUEST_SOURCE_WORKTREE"

exec ssh -T -o BatchMode=yes "$PVM_VALIDATION_HOST" \
  "cd '$PVM_REMOTE_ROOT' && ./scripts/test/run-ubuntu-24.04-basic.sh '$ACTION' '$remote_profile'"
