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

The workflows are:

| Workflow | Trigger | Work |
| --- | --- | --- |
| `checks.yml` | Push, pull request, manual | Shell syntax, target pins, unit tests |
| `prepare-images.yml` | Manual, default branch | Prepare or reuse sealed vendor images |
| `rpm-test.yml` | Manual, default branch | Reuse images, build RPMs, run every runtime gate |
| `release.yml` | Manual, default branch | Freeze latest OOT heads, qualify all targets, publish RPMs |

Image preparation and RPM testing accept a single `target` or `all`. The matrix is
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

All VM workflows share workflow-level concurrency group `pvm-factory`
and run targets serially. This prevents preparation, qualification and release
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

## One-click release

Run `PVM OOT release` on the default branch; no source SHA input is needed.
Optionally enter `release_tag`, such as `v0.1.0` or `pvm-oot-v0.1.0`; leaving
it blank generates a tag automatically. Names may contain letters, digits,
dots, underscores and hyphens, must start with a letter or digit, and must
be valid under the checked naming rules. Existing tags are rejected before
building and atomically refused at publication; they are never overwritten.
It resolves `virt-pvm/linux` branches `pvm-6.6-host-oot` and
`pvm-6.12-host-oot` once, then uses those exact commits throughout the run.
The frozen branch commits select the profiles and preparation tools, not the
source version to build. Each kernel-owned profile supplies its fixed
`source.commit`, source fingerprint, target headers, compiler requirements and
complete patch series. The release uses these pins verbatim, without rewriting
the profile or dropping already-applied patches. Missing source commits,
fingerprint mismatches and patch conflicts fail; maintainers must fix the
profiles in the kernel repository. Release provenance records both the branch
commit that supplies the profile and the actual pinned source commit.

The hosted snapshot job packages a full context Git bundle and all pinned
OOT source bundles as one run-scoped artifact. The validation job downloads
that artifact and checks out the exact context SHA locally, without using
`actions/checkout` or fetching Linux Git objects over the host's Internet
connection. Input file checksums and the frozen plan are verified before use;
the usual guest-side profile and source-fingerprint checks still apply.

Artifact IDs are passed through the producing job's outputs. A failed-job
retry reuses the successful dependency's exact artifact even when its attempt
number differs; uploads and private working directories remain attempt-scoped.
Retrying publication still refuses an existing tag or release.

The protected build job uses `PVM_FACTORY_CONFIG_DIR` and existing sealed
images on the validation host. It generates a private temporary context and
target pins, without committing or altering the checked-in manifests. Factory
envs must select `PVM_FACTORY_HOST=local`. All targets run serially through the
same `pvm-ci run` gates, including persisted-template restore. Runtime binaries
are reused and their backing-disk SHA256 is recorded; they are not updated by
the release. Failures stop publication; diagnose them in the job logs and
retained host-side artifacts.

Only after every target passes does a hosted job receive `contents: write`.
It verifies checksums, creates a draft, uploads the tested RPMs and public
`release-manifest.json`/`SHA256SUMS`, and publishes the draft automatically.
No private envs, full logs, keys or VM disks are released. The generated tag is
`pvm-oot-<UTC date>-<run ID>-<attempt>`; generated and manual tags both point
to the context commit. An upload failure can leave a tag and draft for
inspection, never a published partial release. Existing tags/assets are not
overwritten; use a new manual tag on retry, or leave the input blank for a
new attempt suffix.

The snapshot job reads the most recently published non-prerelease PVM release
and its manifest. Each OOT line records previous/current SHAs, added commits,
removed commits for rewritten history, and a compare link. First releases and
unchanged branches are explicit. A missing prior manifest or inaccessible old
commit fails the release rather than silently dropping history. Release notes
contain the same summaries. These comparisons describe profile/tooling branch
history; actual source pins are recorded per target. Linux Git fetches run
on the hosted runner; no personal token or SSH deploy key is required for
that public repository. The validation host still needs connectivity to
GitHub Actions and artifact storage.
