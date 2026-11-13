# Prepared VM Image Pipeline

All six targets use a vendor cloud image and an exact vendor kernel release
from `targets/*/*/manifest.txt`. Ubuntu 24.04's optional custom 6.6/6.12 host
test image is separate; it is not the RPM qualification image. Amazon's KVM
image initially boots 6.1; provisioning installs the pinned official 6.18
kernel and its matching development package.

## Inputs

- `images/profiles.json`: public image URLs, distro package names, compiler
  selection. Target manifests remain authoritative for kernel/source pins.
- Optional `targets/<distro>/<kernel>/image.json`: target-specific overrides
  of the family image profile. Use it for archived native kernel and matching
  toolchain RPM URLs; never change all targets to accommodate one old kernel.
  `compiler_packages` replaces the default RPM compiler package requests;
  `packages` adds other dependencies. Do not request an unversioned compiler
  and a conflicting pinned compiler together.
- A trusted external factory env, based on `configs/factory.env.example`.
  Physical host login belongs in SSH config, not in the repository.
- A checksum-pinned, read-only shared runtime qcow2 containing the existing
  Kata Rust shim, QEMU/Dragonball/Cloud Hypervisor, CubeSandbox, PVM guest
  kernels, and runtime state. Runtime binaries are not reinstalled per distro.
- Manifest-pinned clean OOT source exports, generated from an external Git
  cache. The exporter ignores dirty worktree contents and verifies the profile
  checksum. Local DNS helpers stay outside Git and are included by content hash.

Prepare the clean source input once per target pin change:

Alternatively set `PVM_OOT_REPO` to an external Git cache on the validation host;
the pipeline exports the pinned source automatically on every invocation.

```bash
python3 tools/export-oot-source.py ubuntu-24.04/6.8.0-139 \
  --repo /path/to/oot-66-git-cache \
  --output /srv/pvm-assets/oot-source/ubuntu-24.04-6.8.0-139.tar.gz
```

Use the 6.6 base for kernels below 6.12 and the 6.12 base for 6.12 and later.
Do not silently advance missing Git objects or substitute another kernel.
The `.sha256` sidecar is part of the trusted source input; move both via the
same trusted deployment path. It is integrity checking, not an upstream signature.

## Commands

```bash
# Official image -> headers/tools/runtime -> reboot -> verify -> sealed disks.
scripts/pvm-ci prepare ubuntu-24.04/6.8.0-139 --env /srv/pvm-private/ubuntu24.env

# Explicitly rebuild without deleting the previous sealed image.
scripts/pvm-ci prepare ubuntu-24.04/6.8.0-139 --env /srv/pvm-private/ubuntu24.env --force

# New root/shared overlays -> fresh prepare.py -> RPM -> all runtime gates.
scripts/pvm-ci run ubuntu-24.04/6.8.0-139 --env /srv/pvm-private/ubuntu24.env

# Prepare if absent, then run the same complete qualification.
scripts/pvm-ci all ubuntu-24.04/6.8.0-139 --env /srv/pvm-private/ubuntu24.env
```

`prepare` validates the official image SHA256, runtime disk SHA256, exact
header hashes, compiler identity, pahole version and resolver availability.
It installs native kernel/header packages, builds only the BTF resolver if
needed, mounts `/build` at boot, configures shared runtime services, and sets
the exact default boot kernel with `nokaslr`. It never formats a runtime disk.
Versioned official Ubuntu pool packages or an apt snapshot can supply old
ABIs no longer present in a rolling package index. Toolchain package versions
can be pinned through `PVM_EXTRA_PACKAGES`; mismatches fail before building.
`PVM_CC` selects the compiler executable, still subject to the header identity
check. `PVM_GUEST_PREPARE_HOOK` optionally configures archived RPM repositories
or installs site-specific toolchain packages inside the VM before provisioning;
it stays outside Git and participates in the image recipe through its SHA256.

For an RPM target with `kernel_rpms`, all declared packages are installed
together, including matching compiler packages when required. Supply an
optional `PVM_KERNEL_RPM_CACHE_DIR` for slow or archived official repositories.
Each declared URL's basename must exist there with a `.sha256` sidecar from
the trusted input acquisition step. The controller checks every checksum,
stages only the declared files, and records their hashes in the image recipe.
A missing or corrupt cache entry fails preparation rather than silently
substituting a different kernel or compiler. Without a cache, DNF uses the
declared official URLs directly.

SELinux remains enabled on enforcing distributions. Provisioning installs
persistent contexts for the shared runtime and Docker/containerd state, then
relabels only the VM's writable overlay. Native kernel module packages must
include the networking modules used by Docker and Cube's TPROXY rules.
Readiness also requires Cube's configured NVMe/TCP controller grid to be live;
a Type=simple service being active is not sufficient to seal or test an image.

An image is published only after provisioning, a second boot, environment
verification, clean shutdown, and `qemu-img check`. Failed preparation never
replaces `current.json`. Sealed templates and their runtime backing disk must
remain at their recorded paths. Re-run `prepare` after provisioning/catalog,
kernel or runtime changes; `all` reuses an existing image. Each `run` refreshes
configured external DNS helpers, verifies their staged hashes, restarts their
services, and checks wildcard Cube DNS before building. This permits local
DNS maintenance without reinstalling runtime binaries or publishing the
helper scripts. Active helper hashes are recorded in run provenance.

Every `run` creates **both** root and shared qcow2 overlays. It prepares the
current pinned OOT source anew, builds and installs an RPM, verifies BTF,
tests Firecracker and Kata's three hypervisors, and runs Cube template/restore.
Finally it creates a template, powers off/recreates the outer VM with the
**same** two working disks, and restores the same template ID. No live writable
disk is shared between different test instances. Different targets can run in
parallel; a per-target lock serializes competing runs for the same target.

Successful working disks are removed by default; `PVM_KEEP_DISKS=1` retains
them. Failed working disks and console/provisioning logs are retained outside
the checkout. RPMs, qualification logs, and provenance go into ignored
`.artifacts/pipeline/`. Private keys and external env files must not be uploaded.

## Actions

Deploy the public checkout to a KVM/nested-capable self-hosted runner, configure
the external inputs, and run `prepare` manually before enabling the workflow.
The Action should call `run`, not recreate or update the OS on every commit.
Use protected environments and trusted branches only: these scripts execute
privileged VM commands. Do not run untrusted pull-request code on this runner.
Read `docs/self-hosted-ci.md` for runner deployment and artifact boundaries.
Publishing workflows and registering a runner are separate deployment steps.

The image catalog is configuration, not proof that every fresh-image path is
qualified. Keep actual validation results in ignored artifacts, not here or
in target manifests.
