---
name: pvm-oot
description: Adapt or update a PVM out-of-tree host profile for a distribution kernel, including base selection, format-patch generation, and pin validation.
---

# PVM OOT adaptation

Work on the external 6.6 or 6.12 OOT base, not a duplicate source in this repository. Select the 6.6 base for 6.6 <= kernel < 6.12 and the 6.12 base for Linux 6.12 through 7.0, including the pinned Ubuntu 26.04 target. Do not infer compatibility with unlisted kernels from this range alone. Read `docs/oot-profile-patches.md` before changing a profile.

Generate regular mail-format patches with `git format-patch`; update the profile hashes in the base and the target manifest here. Run the base's `tools/pvm-oot/prepare.py` against the exact kernel build. Follow `skills/pvm-validation/SKILL.md` for RPM build and complete qualification, including cross-reboot template restore. Move adaptation fixes back to the selected base. Keep test results in ignored artifacts, not tracked manifests.

Before reporting a target as qualified, confirm the prepared source metadata matches the target's base commit, profile SHA256, and kernel release. Do not change the other base, unrelated profiles, or publish commits unless requested.
