# PVM Context

This repository is the working context for PVM development and validation. It
is not intended to replace the Linux source trees. Instead, it keeps the
cross-repository knowledge that is needed to build and test PVM repeatably:

- branch and commit provenance for PVM Linux variants;
- design notes and cross-component contracts;
- VM runtime setup and smoke-test scripts;
- AI helper instructions for safe, repeatable agent work.

The main source trees live outside this repository in configurable worktrees.
The context repository points to those trees through pin metadata and target
configuration rather than through submodules.

## Repository Layout

```text
docs/       Architecture, contracts, workflows, troubleshooting, and PRDs.
pins/       Branch aliases, upstream branches, pinned commits, and local
            override policy for external source trees.
scripts/    Build, environment setup, smoke-test, and target helper scripts.
skills/     Agent-facing task workflows for PVM development and testing.
tools/      Small local helper tools used by scripts or validation.
.artifacts/ Local run output, logs, and temporary generated files.
```

## Branch Pin Design

PVM uses several Linux branches for different integration lines. The context
repository tracks them as logical aliases instead of submodules. The initial
branch set is:

| Alias | Upstream branch | Purpose |
|---|---|---|
| `pvm-6.7` | `pvm` | Original PVM Linux line. |
| `pvm-6.12` | `pvm-612` | Linux 6.12 PVM line. |
| `pvm-host-66-oot` | `pvm-6.6-host-oot` | OOT host modules for 6.6 <= kernel < 6.12. |
| `pvm-host-612-oot` | `pvm-6.12-host-oot` | OOT host modules for 6.12 and newer kernels. |

The pin files should record both the upstream branch and the exact commit SHA.
The branch name answers "where should updates come from?" The commit SHA
answers "what was this context validated against?"

Local development can use an ignored local override file, for example
`pins/local.override.yaml`, to point an alias at a developer branch or dirty
worktree. Build and test reports should always record the actual source SHA and
whether the tree was dirty, so local experiments do not get confused with a
validated baseline.

## Automated Test Scripts

The Ubuntu 24.04 basic workflow keeps the context checkout as a controller and
runs image creation, kernel builds, and virtualization tests on a separate KVM
validation host. It downloads the official Ubuntu 24.04 cloud image, creates an
independent shared build disk, installs Kata Containers, and builds the pinned
6.6 and 6.12 host bases plus their matching PVM OOT modules.

The runtime matrix covers direct Firecracker boot plus Kata runtime-rs with
QEMU, Cloud Hypervisor, and Dragonball. Kata and Firecracker releases are
pinned and checksum-verified; QEMU uses the supported q35 machine with qboot.
Machine-specific host names, source paths, and local
archives belong in the ignored `configs/ubuntu-24.04-basic.local.env` profile.
See `docs/test-env.md` for prerequisites, profile examples, and phase commands.

The scripts in `scripts/` also provide focused build and smoke-test automation
after the selected PVM kernel or module is deployed:

- target helpers prepare the VM, kernel source, and module build environment;
- `firecracker-pvm-test.sh` validates the Firecracker PVM path and checks for
  host warnings, refcount warnings, Oopses, and guest boot failures;
- environment and log helpers keep setup and failure collection repeatable.

Run the complete remote workflow from the controller:

```bash
./scripts/test/run-on-validation-host.sh all \
  configs/ubuntu-24.04-basic.local.env
```

After deploying the selected kernel or module, run the relevant validation
script:

```bash
sudo ./scripts/firecracker-pvm-test.sh
```

The Firecracker test uses the configured VMM binary, PVM guest kernel, and guest
image. It detects either the `kvm_pvm` or PVM-backed `kvm_amd` module, waits for
the guest to boot, and fails on host refcount warnings, kernel warnings, or an
Oops. Set `PVM_MODULE` to override automatic module selection.

## Distribution OOT RPM Profiles

The `targets/<distribution>/<kernel>/` directories hold VM connection
profiles and target pin manifests. OOT source and target-specific patches
remain in the selected external 6.6 or 6.12 base repository; this context
repository does not duplicate the Linux source tree. Follow
`docs/oot-profile-patches.md` when updating those patches.

To build, install, and smoke-test a pinned target from `dev`:

```bash
./build-ko-rpm.sh targets/centos-stream-10/6.12.0-267/config.sh
```

Use `PVM_ARTIFACT_DIR` to keep a new run separate from previously qualified
RPMs. The profile supplies the VM login method, prepared source directory,
target kernel, and post-install test. The guest-side build checks that the
running kernel and GCC match the target build tree. When module BTF is
enabled, it also checks the configured `pahole` version, prepares a BTF base
from the running kernel if needed, and verifies BTF in both the built and
installed modules. CentOS Stream 10 and Amazon Linux 2023 profiles can
install `dwarves` from their official repositories when it is missing.

The RPM and its SHA256 and build manifest are written to the profile's
artifact directory. Tracked target manifests record only distribution,
kernel, source, and profile pins. Keep per-run results and RPM checksums in
ignored logs and artifact directories, not in tracked target manifests.
Keep the prepared source aligned with the pinned profile before running the
build. Current profiles cover Ubuntu 24.04,
Ubuntu 26.04, CentOS Stream 10, Amazon Linux 2023, and Alibaba Cloud Linux 4.

## AI Helper Workflow

`AGENTS.md` and `skills/` define the rules for AI-assisted PVM
work. The intended model is:

- inspect and modify source trees in their configured external worktrees;
- keep source-tree edits in the external repositories;
- keep cross-repository decisions, target matrices, docs, and helper scripts in
  this context repository;
- never treat a dirty local branch as a validated pin unless the test report
  records the actual SHA and dirty state;
- prefer focused build and smoke-test targets before broad validation.

The helper files are intentionally part of the repository. They should evolve
with the PVM workflow instead of living only in private chat history.
