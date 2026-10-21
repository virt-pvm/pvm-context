# PVM OOT profiles

When adding or updating an OOT distribution profile, follow
`docs/oot-profile-patches.md`. Keep generated `git format-patch` mail files as
regular files in the selected 6.6 or 6.12 base. Do not use bare diffs or
symlinks. Update the profile SHA256 values and run `prepare.py` plus the
target's build and runtime gates. Keep qualification results in ignored
per-run artifacts, not in tracked target manifests.
