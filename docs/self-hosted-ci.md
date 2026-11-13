# Self-hosted PVM validation

Keep GitHub Actions workflows in this context repository. The Linux checkout
provides OOT source and distribution profiles; it does not need a workflow.
Use the same command-line entrypoints for local deployment and CI jobs.

## Validation host

The validation host needs KVM with nested virtualization, QEMU, qemu-img,
OpenSSH, Python 3, and enough storage for immutable images and writable
overlays. Keep the controller checkout, VM keys, and local environment file
outside the target images. Only the distribution VM installs or reloads the
PVM kernel modules.

Migrate images while their QEMU process is stopped. Check the full backing
chain and verify transfer checksums before starting the destination VM.
An export VM may remove unused build trees and trim free blocks in private
overlays before exporting standalone images. Never modify the source images
or a backing image that other overlays still reference.

Create a writable root overlay and a writable shared-disk overlay for the
target. Keep their backing images immutable. The shared disk supplies Kata,
CubeSandbox, guest kernels, and test assets without reinstalling binaries.
Both writable overlays must survive the reboot-restore test.

## Environment and commands

Start from `configs/targets.local.env.example`. Store the real environment
outside the checkout and select it with `--env`. It binds a target to its
host, VM name, SSH port, key, disks, and QEMU binary. The SSH host may be
localhost when the controller runs on the validation host; configure
noninteractive authentication for that connection too.

Set `PVM_JOBS` to no more than half the VM's vCPU count. The target kernel,
compiler, BTF inputs, prepared-source metadata, and profile pins must match.
Check GRUB saved entries and configuration drop-ins when selecting the
pinned kernel, and enable a serial console for boot diagnostics.

```bash
./scripts/pvm-test ubuntu-24.04/6.8.0-139 --reboot-restore --env /path/to/targets.env
# Rerun only the persisted-template gate:
./scripts/pvm-reboot-restore ubuntu-24.04/6.8.0-139 --env /path/to/targets.env
```

The first command builds and collects the RPM, installs it, and runs
Firecracker, Kata QEMU/Dragonball/Cloud Hypervisor, and CubeSandbox
template/restore, followed by the persisted-template gate. The second command
runs that gate alone: it creates a template, records its ID and the VM boot
ID, powers off the VM, and restarts QEMU with the same writable disks. It
waits for the pinned kernel and CubeSandbox services, restores that exact
template, and cleans it up. Run logs and results live in ignored
`.artifacts/` directories.

## GitHub integration

Register a dedicated runner only after these commands work directly on the
deployed environment. Keep credentials and machine bindings outside the
checkout. Initially run the target matrix serially with a protected manual
trigger. Increase parallelism only with separate runner slots and independent
VM overlays. Use workflow-level concurrency to avoid dropping pending matrix
jobs that share one job-level concurrency group.

Every source update must prepare a fresh tree from an explicit source SHA
and matching profile before the RPM command. Validate that the source tested
is the source requested. Qualify and review workflow changes before publishing
them to GitHub.
