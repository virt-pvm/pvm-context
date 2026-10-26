#!/usr/bin/env python3
"""Check tracked target pin manifests without executing target shell code."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
targets = sorted((root / "targets").glob("*/*/config.sh"))
if not targets:
    raise SystemExit("no target profiles found")
errors = []
for config in targets:
    manifest = config.with_name("manifest.txt")
    if not manifest.is_file():
        errors.append(f"{config}: missing manifest")
        continue
    entries = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            errors.append(f"{manifest}: malformed line")
            continue
        key, value = line.split("=", 1)
        entries[key] = value
    for key in ("distribution", "kernel_release", "base_commit", "profile", "profile_sha256"):
        if not entries.get(key):
            errors.append(f"{manifest}: missing {key}")
    if not re.fullmatch(r"[a-f0-9]{40}", entries.get("base_commit", "")):
        errors.append(f"{manifest}: invalid base_commit")
    if not re.fullmatch(r"[a-f0-9]{64}", entries.get("profile_sha256", "")):
        errors.append(f"{manifest}: invalid profile_sha256")
    text = config.read_text(encoding="utf-8")
    for key in ("PVM_KERNEL_RELEASE", "PVM_BASE_COMMIT"):
        match = re.search(rf"^{key}=([^\n]+)$", text, re.MULTILINE)
        expected = entries.get("kernel_release" if key == "PVM_KERNEL_RELEASE" else "base_commit")
        if not match or match.group(1).strip("'\"") != expected:
            errors.append(f"{config}: {key} differs from manifest")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
print(f"validated {len(targets)} target pin manifests")
