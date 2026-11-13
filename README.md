# PVM Context

PVM kernel sources: [virt-pvm/linux](https://github.com/virt-pvm/linux).

This repository provides the packaging and validation workflows for PVM
out-of-tree (OOT) host modules. Linux sources and distribution adaptations
remain in their kernel repositories.

## Features

- Build target-specific module RPMs with compiler and BTF checks.
- Prepare reusable distribution VMs with independent root/shared overlays.
- Validate Firecracker, Kata runtime-rs, and CubeSandbox on PVM.
- Maintain source/profile pins, workflow documentation, and repository skills.

## Linux Branches

| Branch | Purpose |
| --- | --- |
| `pvm` | Original Linux 6.7 PVM development line. |
| `pvm-612` | Linux 6.12 PVM host/guest development line. |
| `pvm-6.6-host-oot` | OOT host integration for `6.6 <= kernel < 6.12`. |
| `pvm-6.12-host-oot` | OOT host integration for Linux 6.12 through 7.0. |

Each target pins its exact baseline and adaptation profile in
`targets/<distribution>/<kernel>/manifest.txt`; builds do not follow branch
tips automatically. Kernel compatibility is specific to the targets below.

## Supported Distributions

Current x86_64 RPM targets:

| Distribution | Host kernel |
| --- | --- |
| Ubuntu 24.04 LTS | `6.8.0-139-generic` |
| Ubuntu 26.04 LTS | `7.0.0-30-generic` |
| CentOS Stream 10 | `6.12.0-267.el10.x86_64` |
| Amazon Linux 2023 | `6.18.54-121.166.amzn2023.x86_64` |
| Alibaba Cloud Linux 4 | `6.6.102-7.alnx4.x86_64` |
| OpenCloudOS 9.4 | `6.6.119-52.9.oc9.x86_64` |

## Packaging And Testing

1. Prepare an official cloud image with the pinned native kernel, headers,
   toolchain, and shared runtime assets; verify and seal the VM disks.
2. Start fresh root/shared overlays, prepare the pinned OOT source, and build
   an RPM. Runtime binaries are reused rather than reinstalled per run.
3. Install the RPM and check module loading/BTF, Firecracker boot, Kata
   QEMU/Dragonball/Cloud Hypervisor, and CubeSandbox template creation/restore.
4. Recreate the outer VM with the same writable disks and restore the same
   template. Collect the RPM, SHA256, build manifest, and logs.

```bash
# Prepare once; reuse the sealed image for subsequent runs.
./scripts/pvm-ci prepare ubuntu-24.04/6.8.0-139 --env /path/to/factory.env
./scripts/pvm-ci run ubuntu-24.04/6.8.0-139 --env /path/to/factory.env
```

`scripts/pvm-ci all` prepares a missing image and runs the full flow.
`scripts/pvm-build` provides build-only or test-only operations for an
already prepared VM. Generated packages and results stay in `.artifacts/`.

The GitHub workflows separate static checks (`checks.yml`), manual image
preparation (`prepare-images.yml`), and manual full qualification (`rpm-test.yml`).

Setup details: [image preparation](docs/image-factory.md),
[self-hosted CI](docs/self-hosted-ci.md), and
[OOT adaptation rules](docs/oot-profile-patches.md).
