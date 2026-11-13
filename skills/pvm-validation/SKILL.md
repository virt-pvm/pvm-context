---
name: pvm-validation
description: Prepare PVM distribution VMs, build module RPMs, run full Firecracker/Kata/CubeSandbox qualification including cross-reboot template restore, or diagnose failures. Source adaptation belongs to pvm-oot.
---

# PVM build and validation

Run commands from the context repository root. Use the same tracked entrypoints
for manual runs and CI; read `docs/image-factory.md` for factory inputs and
`docs/self-hosted-ci.md` for runner deployment and existing-VM bindings.
Use `docs/test-env.md` only for the separate Ubuntu custom 6.6/6.12 host
development workflow, not native distribution RPM qualification.

## Choose the scope

- Prepare a reusable official image: `scripts/pvm-ci prepare <distribution/kernel> --env <factory-env>`. Reuse a matching sealed image; rebuild deliberately when its inputs change.
- Build and fully qualify: `scripts/pvm-ci run <distribution/kernel> --env <factory-env>`. This creates isolated root/shared overlays and freshly prepares pinned OOT source. Use `all` instead of `run` when an absent image should be prepared first.
- Build only on an already prepared VM: `scripts/pvm-build <distribution/kernel> --build-only --env <vm-env>`.
- Test an existing guest-side RPM: `scripts/pvm-test <distribution/kernel> --env <vm-env> --reboot-restore --test-only --rpm <guest-rpm-path>`. Omit `--test-only --rpm ...` to build and test on that VM. First regenerate the pinned prepared source when building; metadata checks alone do not prove an old working tree is unmodified.

Factory envs and existing-VM envs have different roles; do not interchange them.
Treat build-only, `--module-only`, individual hypervisor tests, and standalone
restore reruns as partial checks, not complete qualification.

## Preserve reproducibility and isolation

Keep kernel, base commit, and profile pins in tracked target manifests; keep
machine bindings, credentials, and private paths in external or ignored envs.
Never print private env values or publish keys, images, or generated RPMs
without a request. Verify the VM kernel, headers, compiler and BTF tools;
do not weaken checks to accept a rolling-repository replacement. Keep family
image defaults in `images/profiles.json` and target-specific native kernel or
toolchain overrides in `image.json`; trusted RPM caches need SHA256 sidecars.

Build inside the validation VM with at most half its vCPUs, not on the
development machine. Reuse the immutable shared runtime instead of installing
Kata/Cube binaries per distro. Give each VM its own writable root/shared
overlays and preserve both disks across the reboot-restore gate. Never modify
a shared backing disk or discard existing user disks/snapshots as a repair.
Keep vendor SELinux enabled with persistent contexts for runtime executables
and Docker/containerd state. Keep local DNS helpers outside Git; the factory
refreshes them and records their hashes on each run.

## Qualification and diagnosis

Complete qualification requires module load/BTF, direct Firecracker boot,
Kata runtime-rs with QEMU, Dragonball and Cloud Hypervisor, CubeSandbox
template creation/restore, and restoration of the same template after the
outer VM is stopped and recreated with the same writable disks.

Require a zero exit status from the selected full-flow command. A factory
run finishes with `PVM_PIPELINE=PASS`; the existing-VM path must complete
both `PVM_FULL_TEST=PASS` and `PVM_REBOOT_RESTORE=PASS` in the same run.
`PVM_FULL_TEST=PASS` alone does not include the cross-reboot gate. An image
catalog entry or an earlier successful run is not evidence for the current run.

Collect the RPM, SHA256, build manifest, build/test/Kata/Cube logs, and
reboot-restore evidence in ignored per-run artifacts. Distinguish missing
VM/assets, source-pin, compiler/BTF, module-load, runtime and reboot-restore
failures. Use individual runtime scripts for focused diagnosis inside the
VM, not as substitutes for orchestration. Report failed and partial gates
explicitly; do not turn a successful rerun into a claim that the first run passed.
