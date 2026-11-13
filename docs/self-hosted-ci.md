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

The three independent workflows are:

| Workflow | Trigger | Work |
| --- | --- | --- |
| `checks.yml` | Push, pull request, manual | Shell syntax, target pins, unit tests |
| `prepare-images.yml` | Manual, default branch | Prepare or reuse sealed vendor images |
| `rpm-test.yml` | Manual, default branch | Reuse images, build RPMs, run every runtime gate |

Both manual workflows accept a single `target` or `all`. The matrix is
resolved from checked-in manifests by `tools/ci-matrix.py`; unknown targets
fail before any VM starts. Update the choice menus when adding a target.
Configure the protected `pvm-validation` environment and its
`PVM_FACTORY_CONFIG_DIR` variable. Each target resolves an external env named
`<distribution>-<kernel>.env` in that directory. Do not store real bindings or
credentials in workflow YAML.

Image preparation's `force` boolean maps to `scripts/pvm-ci prepare ... --force`.
Without it, a checksum-verified image with a matching recipe is reused.
Forced preparation creates a new candidate and publishes it only after
verification; it never deletes the previous image or its backing chain.
RPM testing always calls `run`, never `prepare` or `all`, and has no reduced
test mode. It uploads only the selected target's ignored RPM/test artifacts;
images, private env files, SSH keys, and local DNS helpers are not uploaded.

The two manual workflows share workflow-level concurrency group `pvm-factory`
and run their matrices serially. This prevents preparation and qualification
from competing for a site's fixed forwarded port. Running jobs are not
cancelled by a new dispatch. This is not a FIFO queue: GitHub may replace a
pending run with a newer pending run. Do not dispatch multiple pending batches
when every batch must be retained.

Host-side validation can lint the YAML and execute its `run` blocks with
external env bindings, including real VM preparation and complete tests. It
does not validate GitHub dispatch, runner scheduling, environment approvals,
checkout, or artifact upload. Those require a registered runner and published
workflow; keep that distinction explicit until GitHub execution is verified.

Before publishing, validate the workflow expressions and runner labels with
`actionlint -config-file .github/actionlint.yaml .github/workflows/*.yml`.
The generic `pvm` capability label is declared there; hostnames and addresses
remain in external SSH/env configuration.

Register a dedicated runner only after these commands work directly on the
deployed environment. Keep credentials and machine bindings outside the
checkout. Initially run the target matrix serially with a protected manual
trigger. Increase parallelism only with separate runner slots and independent
VM overlays. Use workflow-level concurrency to avoid dropping pending matrix
jobs that share one job-level concurrency group.

On a systemd host, run the registered runner through its supplied service
wrapper, not an interactive SSH terminal. From the runner directory, run
`sudo ./svc.sh install <runner-user>` once, then `sudo ./svc.sh start` and
`sudo ./svc.sh status`. Installation enables startup at boot. Select the
dedicated runner account deliberately; an existing root runner may use
`root` explicitly. Stop any manually started listener before starting the
service, and verify that it reports `Listening for Jobs`.

Every source update must prepare a fresh tree from an explicit source SHA
and matching profile before the RPM command. Validate that the source tested
is the source requested. Qualify and review workflow changes before publishing
them to GitHub.
