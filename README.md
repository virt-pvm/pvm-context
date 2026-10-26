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

### One-command VM, RPM, and runtime workflow

`scripts/pvm-test` is the entrypoint for an already provisioned target image:

```bash
./scripts/pvm-test ubuntu-26.04/7.0.0-30 --env configs/targets.local.env
./scripts/pvm-test ubuntu-26.04/7.0.0-30 --vm-only
```

It connects to the physical validation host, checks the QEMU name, SSH port,
root disk, and per-VM shared-disk overlay, and starts the VM if it is stopped.
It then waits for the pinned kernel and shared mount before running
`scripts/pvm-build` (RPM, Firecracker, Kata, and CubeSandbox). A running VM
with mismatched disks or port is rejected rather than restarted. Image
creation and destructive CubeS3lvol cleanup remain separate, explicit tasks.

Keep the SSH host, guest credentials, VM name, root and shared disk paths,
optional seed ISO, QEMU path, CPU/memory sizing, and sudo policy in an ignored
`configs/targets.local.env` (see the example). The tracked startup logic is
`scripts/vm/ensure-qemu.sh`; it receives no guest password. A host that
requires root to use KVM needs narrowly scoped noninteractive QEMU permission
for the runner; never put a sudo password in the repository or command line.
The `--vm-only` option checks or starts the VM without building.

### One-command RPM workflow

Each target keeps immutable kernel, base, and profile pins in
`targets/<distribution>/<kernel>/manifest.txt`. Its `config.sh` currently
provides build and runtime commands; the connection functions in older configs
are ignored by the new entrypoint. Machine-specific SSH details stay in an
ignored env (start from `configs/targets.local.env.example`).

```bash
./scripts/pvm-build centos-stream-10/6.12.0-267 --env configs/targets.local.env
./scripts/pvm-build centos-stream-10/6.12.0-267 --build-only --env configs/targets.local.env
./scripts/pvm-build centos-stream-10/6.12.0-267 --test-only \
  --rpm /path/in/guest/pvm-oot-kmod.rpm --env configs/targets.local.env
```

The first form builds and tests. The build stage checks the prepared source
metadata against the target's base commit, profile SHA256, and kernel release,
checks the matching compiler and module BTF inputs, and builds the RPM. It
checks prepared metadata, not a fresh byte-for-byte hash of a previously
built source tree. For release qualification, regenerate the prepared tree
from the pinned base and profile before invoking this command.
It collects the RPM, SHA256, build manifest, and logs under
`.artifacts/rpm/<target>/<run>/` and verifies the collected RPM hash. The
test stage installs the RPM in the VM, verifies the loaded module path and BTF,
then runs the target's configured runtime smoke test, Kata QEMU/Dragonball/
Cloud Hypervisor, and CubeSandbox template creation and restore. The command
fails unless all gates pass. Use `--module-only` to stop after the target's
runtime smoke test when debugging. The full test writes `test.log`,
`kata.log`, and `cube.log` under the run output directory.

The env can set `PVM_SSH_HOST`, `PVM_VM_PORT`, `PVM_VM_USER`, and either
`PVM_VM_KEY` (a path on the SSH host) or `PVM_VM_PASSWORD`. Prefer a VM key
and a trusted SSH host key. `PVM_OUTPUT_DIR` and `PVM_JOBS` are optional.
For nonstandard VM layouts, set `PVM_KATA_CONFIG_DIR`, `PVM_CUBE_ENV_FILE`,
and `PVM_CUBE_ROOT` in the ignored local env.
`PVM_KATA_SHIM_OVERRIDE` can point to a guest-side shim binary; the test
bind-mounts it over the system shim only for the Kata phase and then unmounts it.
The target manifest's kernel and base pins cannot be overridden by the env.
For CI, provision the same env outside the checkout on a protected self-hosted
runner; do not put credentials in a tracked target, Skill, or workflow log.
The VM must already have the pinned kernel and headers, prepared OOT source,
compiler/BTF tools, RPM tooling, and runtime test assets. Image creation is
not part of this command.

The older `build-ko-rpm.sh` remains available for migration but couples
build, install, and test and does not collect RPMs to the controller. New
automation should use `scripts/pvm-build`.

Legacy entrypoint, kept for existing callers:

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
Ubuntu 26.04, CentOS Stream 10, Amazon Linux 2023, Alibaba Cloud Linux 4,
and OpenCloudOS 9.4.

## Repository Skills

The repo-local Skills in `skills/` guide adaptation, VM preparation, RPM
build, and runtime validation. `AGENTS.md` routes those tasks when working
inside this repository. To invoke them as global Codex Skills from outside
the repo, install or link their directories into `$CODEX_HOME/skills`.

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
