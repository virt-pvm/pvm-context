# Ubuntu 24.04 Basic Validation

The Ubuntu 24.04 profile builds a disposable test VM from the official cloud
image and attaches a per-VM qcow2 overlay backed by an immutable runtime disk.
The backing disk stores the common Kata, CubeSandbox, and tool assets once;
each distribution writes into its own overlay, so validation VMs can run in
parallel without sharing a writable image. The context repository is a
controller only: image creation, kernel builds, and tests execute on a separate
KVM validation host. Machine-specific paths stay in an ignored local profile.

## Host Requirements

- KVM access and an x86_64 QEMU binary
- `curl`, `genisoimage`, `qemu-img`, `rsync`, `scp`, and `ssh`
- base source trees for Linux 6.6 and 6.12
- source trees for the 6.6 OOT line, 6.12 OOT line, and PVM guest kernel
- SSH and rsync access from the controller to the validation host

Create `configs/ubuntu-24.04-basic.local.env`:

```bash
source "$ROOT_DIR/configs/ubuntu-24.04-basic.env"

PVM_VALIDATION_HOST=kvm-validation-host
PVM_REMOTE_ROOT="$HOME/pvm/pvm-context-runtime"
PVM_WORK_DIR="$PVM_REMOTE_ROOT/.artifacts/ubuntu-24.04-basic"
PVM_SHARED_BASE="$HOME/pvm/images/pvm-common-base.qcow2"
PVM_SHARED_OVERLAY="$PVM_WORK_DIR/shared-work.qcow2"

PVM_66_BASE_SOURCE="$HOME/pvm/sources/linux-6.6-base"
PVM_612_BASE_SOURCE="$HOME/pvm/sources/linux-6.12-base"
PVM_66_SOURCE_WORKTREE="$HOME/pvm/sources/pvm-6.6-host-oot"
PVM_612_SOURCE_WORKTREE="$HOME/pvm/sources/pvm-6.12-host-oot"
PVM_GUEST_SOURCE_WORKTREE="$HOME/pvm/sources/pvm-guest"
QEMU_BIN="$HOME/qemu/bin/qemu-system-x86_64"
QEMU_IMG_BIN=qemu-img
QEMU_USE_SUDO=1
VM_MACHINE_TYPE=q35

# PVM host OOT modules require a stable kernel text layout.
PVM_HOST_CMDLINE=nokaslr

# Optional on hosts whose SSH service has a restrictive memory cgroup.
QEMU_CGROUP_PROCS=/sys/fs/cgroup/memory/cgroup.procs

# Optional: use an existing Kata archive instead of downloading one.
KATA_ARCHIVE=/path/to/kata-static-amd64.tar.zst

# Optional: use an existing official Firecracker archive.
FIRECRACKER_ARCHIVE="$PVM_REMOTE_ROOT/cache/firecracker-v1.17.0-x86_64.tgz"
PVM_CONTROL_FIRECRACKER_ARCHIVE=/path/to/firecracker-v1.17.0-x86_64.tgz

# Optional: stage a controller-side tree before running remotely.
PVM_CONTROL_GUEST_SOURCE_WORKTREE="$ROOT_DIR/../guest"
```

The source worktrees may contain local changes. Their commit and dirty state
are recorded before they are copied to the shared disk.

## Workflow

Use the controller wrapper for every phase. It deploys the context and any
configured controller-side source trees before starting the remote phase.

Prepare the official image, shared overlay, shared runtime, and guest kernel:

```bash
./scripts/test/run-on-validation-host.sh prepare configs/ubuntu-24.04-basic.local.env
```

Build and select the fixed 6.6 host base, then test its OOT line:

```bash
./scripts/test/run-on-validation-host.sh build-host-66 configs/ubuntu-24.04-basic.local.env
./scripts/test/run-on-validation-host.sh switch-66 configs/ubuntu-24.04-basic.local.env
./scripts/test/run-on-validation-host.sh test-66 configs/ubuntu-24.04-basic.local.env
```

Build and select the fixed 6.12 host base, then test its OOT line:

```bash
./scripts/test/run-on-validation-host.sh build-host-612 configs/ubuntu-24.04-basic.local.env
./scripts/test/run-on-validation-host.sh switch-612 configs/ubuntu-24.04-basic.local.env
./scripts/test/run-on-validation-host.sh test-612 configs/ubuntu-24.04-basic.local.env
```

The `all` action executes those phases in order. Each OOT line is validated
with direct Firecracker boot first, followed by Kata QEMU, Dragonball, and
Cloud Hypervisor smoke tests, then CubeSandbox template creation and restore.

`PVM_SHARED_BASE` is chmod read-only when the first overlay is created. Never
attach that base directly as a writable QEMU drive. Give every distribution a
different `PVM_SHARED_OVERLAY`; qcow2 backing reads are shared while all guest
writes, logs, build products, and CubeSandbox state remain isolated.

The pinned Kata 4.2.0 static archive supplies runtime-rs, QEMU, Cloud
Hypervisor, Dragonball, the guest image, and supporting tools. Firecracker is
installed independently from its pinned official release. Both archives are
verified with SHA-256 before installation. The generated QEMU configuration
uses the supported `q35` machine, qboot firmware, and virtio-blk-pci instead of
the upstream virtio-pmem root device.

The validation wrapper does not allocate a pseudo-terminal. The runtime test
also uses foreground timeouts, so it behaves consistently both in automation
and when invoked from an interactive SSH session. Before a QEMU test starts,
the configured machine type, firmware, and executable are checked explicitly.

The default fixed releases are 6.6.144 and 6.12.33. The 6.6 OOT source is
accepted only for running kernels in `[6.6, 6.12)`, and the 6.12 OOT source is
accepted only for `[6.12, 7.0)`. The validation wrapper never compiles or runs
virtual machines on the controller.
