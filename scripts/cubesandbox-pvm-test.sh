#!/usr/bin/env bash
set -euo pipefail

ROOT="${PVM_SHARED_ROOT:-/build/pvm-shared}"
CLI="${CUBEMASTERCLI:-/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli}"
API_URL="${API_URL:-http://127.0.0.1:3000}"
IMAGE="${CUBE_TEMPLATE_IMAGE:-cube-sandbox-image.tencentcloudcr.com/opensource/redis:7-alpine}"
LOG_DIR="${LOG_DIR:-$ROOT/logs/cubesandbox-test}"
ENV_FILE="$ROOT/scripts/cubesandbox-template.env"
CUBE_ENV_FILE="${CUBE_ENV_FILE:-$ROOT/runtime/cubesandbox/.one-click.env}"
CREATED_TEMPLATE=""
KEEP_TEMPLATE="${KEEP_TEMPLATE:-0}"

install -d -m 0755 "$LOG_DIR"

json_file_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
    if value is None:
        break
print("" if value is None else value)
PY
}

json_text_field() {
  python3 - "$1" "${@:2}" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
for key in sys.argv[2:]:
    candidate = value.get(key) if isinstance(value, dict) else None
    if candidate is not None:
        print(candidate)
        break
else:
    print("")
PY
}

check_environment() {
  local module_path candidate expected_dns_ip actual_dns_ip s3lvol_enabled
  PVM_HOST_MODULE="${PVM_HOST_MODULE:-}"
  for candidate in "$PVM_HOST_MODULE" kvm_pvm kvm_amd; do
    [[ -n "$candidate" ]] || continue
    module_path="$(modinfo -n "$candidate" 2>/dev/null || true)"
    [[ "$module_path" == */updates/pvm-oot/* ]] || continue
    PVM_HOST_MODULE="$candidate"
    break
  done
  [[ -n "$PVM_HOST_MODULE" ]]
  if ! grep -q "^${PVM_HOST_MODULE} " /proc/modules; then
    modprobe -r kvm_amd kvm_intel kvm_pvm kvm 2>/dev/null || {
      echo "cannot switch KVM vendor module; stop active VMs first" >&2
      return 1
    }
  fi
  modprobe "$PVM_HOST_MODULE"
  grep -q "^${PVM_HOST_MODULE} " /proc/modules
  [[ "$(modinfo -n "$PVM_HOST_MODULE")" == */updates/pvm-oot/* ]]
  [[ -c /dev/kvm ]]
  [[ "$(file -Lb /usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux)" == ELF* ]]
  [[ -f "$CUBE_ENV_FILE" ]] || { echo "CubeSandbox env is missing: $CUBE_ENV_FILE" >&2; return 1; }
  s3lvol_enabled=$(sed -n 's/^ONE_CLICK_ENABLE_S3LVOL=//p' "$CUBE_ENV_FILE" | head -n1)
  if [[ "$s3lvol_enabled" != 0 ]]; then
    [[ -S /var/run/s3lvol.sock ]] || {
      echo "CubeSandbox s3lvol socket is unavailable" >&2
      return 1
    }
  fi
  systemctl is-active --quiet cube-sandbox-cubelet.service || {
    echo "CubeSandbox cubelet service is not active" >&2
    return 1
  }
  systemctl is-active --quiet cube-sandbox-cube-egress.service || {
    echo "CubeSandbox egress service is not active" >&2
    return 1
  }
  [[ -s /etc/cube/ca/cube-root-ca.crt ]] || {
    echo "CubeSandbox egress root CA is unavailable" >&2
    return 1
  }
  expected_dns_ip=$(sed -n 's/^CUBE_SANDBOX_NODE_IP=//p' \
    "$CUBE_ENV_FILE" | head -n1)
  [[ -n "$expected_dns_ip" ]] || {
    echo "CubeSandbox node IP is missing from .one-click.env" >&2
    return 1
  }
  actual_dns_ip=$(getent ahostsv4 test.cube.app | awk 'NR == 1 {print $1}') || true
  [[ "$actual_dns_ip" == "$expected_dns_ip" ]] || {
    echo "CubeSandbox DNS resolved test.cube.app to '$actual_dns_ip', expected '$expected_dns_ip'" >&2
    return 1
  }
  curl -fsS "$API_URL/health" | tee "$LOG_DIR/health.json"
  "$CLI" template list --json > "$LOG_DIR/templates.json"
}

latest_ready_template() {
  python3 - "$LOG_DIR/templates.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    templates = json.load(source).get("data", [])
ready = [
    item for item in templates
    if item.get("status") == "READY"
    and re.search(r"612|6-12|6\.12", item.get("display_name", ""))
]
ready.sort(key=lambda item: item.get("created_at", ""))
print(ready[-1].get("template_id", "") if ready else "")
PY
}

create_template() {
  local alias submit job_id template_id status phase
  alias="pvm-test-$(date +%Y%m%d%H%M%S)"
  submit="$LOG_DIR/template-submit.json"
  "$CLI" template create-from-image \
    --image "$IMAGE" --alias "$alias" --writable-layer-size 2Gi \
    --cpu 500 --memory 512 --detach --json | tee "$submit"
  job_id="$(json_file_field "$submit" job.job_id)"
  template_id="$(json_file_field "$submit" job.template_id)"
  [[ -n "$job_id" && -n "$template_id" ]]
  CREATED_TEMPLATE="$template_id"
  for _ in $(seq 1 120); do
    "$CLI" template status --job-id "$job_id" --json > "$LOG_DIR/template-status.json"
    status="$(json_file_field "$LOG_DIR/template-status.json" job.status)"
    phase="$(json_file_field "$LOG_DIR/template-status.json" job.phase)"
    echo "template=$template_id status=$status phase=$phase"
    [[ "$status" =~ ^(SUCCEEDED|SUCCESS|READY)$ ]] && break
    if [[ "$status" == FAILED ]]; then
      json_file_field "$LOG_DIR/template-status.json" job.error_message >&2
      return 1
    fi
    sleep 5
  done
  [[ "$status" =~ ^(SUCCEEDED|SUCCESS|READY)$ ]]
  if [[ "$KEEP_TEMPLATE" == 1 ]]; then
    cat > "$ENV_FILE" <<EOF
CUBE_TEMPLATE_ID=$template_id
CUBE_TEMPLATE_JOB_ID=$job_id
CUBE_TEMPLATE_ALIAS=$alias
CUBE_TEMPLATE_IMAGE=$IMAGE
HOST_KERNEL=$(uname -r)
EOF
  fi
  echo "$template_id"
}

restore_template() {
  local template_id="$1" create sandbox_id state state_json
  [[ -n "$template_id" ]]
  "$CLI" template info --template-id "$template_id" --json > "$LOG_DIR/template-info.json"
  [[ "$(json_file_field "$LOG_DIR/template-info.json" status)" == READY ]]
  create="$(curl -fsS -X POST "$API_URL/sandboxes" \
    -H 'Content-Type: application/json' \
    -d "{\"templateID\":\"$template_id\",\"timeout\":120}")"
  printf '%s\n' "$create" | tee "$LOG_DIR/restore-create.json"
  sandbox_id="$(json_text_field "$create" sandboxID sandbox_id)"
  [[ -n "$sandbox_id" ]]
  cleanup_sandbox() { curl -fsS -X DELETE "$API_URL/sandboxes/$sandbox_id" >/dev/null || true; }
  trap cleanup_sandbox RETURN
  state=""
  for _ in $(seq 1 60); do
    state_json="$(curl -fsS "$API_URL/sandboxes/$sandbox_id")"
    printf '%s\n' "$state_json" > "$LOG_DIR/restore-state.json"
    state="$(json_text_field "$state_json" state status)"
    [[ "$state" == running ]] && break
    [[ "$state" =~ ^(failed|error|killed)$ ]] && break
    sleep 2
  done
  [[ "$state" == running ]]
  cleanup_sandbox
  trap - RETURN
  echo "CubeSandbox restore passed: template=$template_id sandbox=$sandbox_id"
}

cleanup_template() {
  if [[ -n "$CREATED_TEMPLATE" && "$KEEP_TEMPLATE" != 1 ]]; then
    "$CLI" template delete --template-id "$CREATED_TEMPLATE" \
      > "$LOG_DIR/template-delete.json" || true
  fi
}

check_environment
mode="${1:-all}"
template_id="${2:-${CUBE_TEMPLATE_ID:-}}"
case "$mode" in
  template-create)
    KEEP_TEMPLATE=1
    create_template
    ;;
  restore)
    [[ -n "$template_id" ]] || template_id="$(latest_ready_template)"
    restore_template "$template_id"
    ;;
  all)
    trap cleanup_template EXIT
    create_template
    restore_template "$CREATED_TEMPLATE"
    cleanup_template
    CREATED_TEMPLATE=""
    trap - EXIT
    ;;
  *)
    echo "usage: $0 [all|template-create|restore] [template-id]" >&2
    exit 2
    ;;
esac
