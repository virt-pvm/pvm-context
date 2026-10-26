---
name: pvm-validation
description: Build PVM distribution module RPMs, prepare validation VMs, run Firecracker/Kata/CubeSandbox tests, or diagnose failures. Source adaptation belongs to pvm-oot.
---

# PVM build and validation

Run commands from the context repository root. Use tracked entrypoints for
manual runs and CI. Read `docs/test-env.md` only for the separate Ubuntu
custom 6.6/6.12 host development workflow, not native distro RPM validation.

Use `scripts/pvm-build <distribution/kernel> --build-only --env <vm-env>`
to build on an already prepared VM. For an existing guest-side RPM, use
`scripts/pvm-test <distribution/kernel> --env <vm-env> --test-only --rpm <guest-rpm-path>`.
Omit `--test-only --rpm ...` to build and test on that VM. First regenerate
the pinned prepared source when building; metadata checks alone do not prove
an old working tree is unmodified. Verify the target kernel, compiler and BTF
inputs; collect the RPM, SHA256, build manifest and logs in ignored artifacts.

Keep kernel/base/profile pins in manifests and private machine bindings in
external or ignored envs. Never print credentials. Build inside the validation
VM with at most half its vCPUs, not on the development machine. Reuse shared
runtime binaries but give each VM its own writable root/shared overlays;
never modify a backing disk or discard existing user disks as a repair.

Runtime validation covers module load/BTF, Firecracker, Kata runtime-rs with
QEMU/Dragonball/Cloud Hypervisor, and CubeSandbox template creation/restore.
Require zero exit status and `PVM_FULL_TEST=PASS` for these gates. Build-only,
`--module-only` and individual runtime scripts are partial checks. Distinguish
VM/assets, source-pin, compiler/BTF, module-load and runtime failures. Keep
results outside tracked manifests and report failed or partial gates explicitly.
