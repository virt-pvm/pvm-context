# PVM OOT profile patch rules

This is the canonical patch-format rule for target profiles in both
`host-pvm-66-oot-pr29` and `host-pvm-612-oot-pr29`. Keep the target-specific
profile and its patch files in the selected base repository. Do not change
either base's README solely to record this workflow.

## Create a target patch series

1. Select the correct base for the target kernel. Export the exact pinned source
   roots into a fresh, disposable directory and check the export-tree fingerprint
   against the profile. Never generate a patch from a dirty build tree.
2. Initialize a temporary Git repository in that export and commit the clean
   baseline. Apply only the target's OOT adaptation, then commit each logical
   change with a descriptive kernel-style subject, accurate author and
   `Signed-off-by` trailer. Wrap commit-message prose at 72 columns.
3. Generate the patch files from those commits with `git format-patch`, for
   example:

   ```bash
   git format-patch --numbered --no-signature \
     --output-directory "$profile_dir" "$baseline_commit..HEAD"
   ```

   Commit regular `.patch` files containing the mail envelope (`From <sha>`),
   `From:`, `Date:`, `Subject: [PATCH...]`, the `---` separator and Git diff.
   A bare `git diff`, symlink to another profile, and patch-path text are not
   valid profile patches. Do not hand-edit a generated diff to hide a mismatch;
   fix the source commit and regenerate it. A single-commit export may use
   `[PATCH]`; multi-commit series should use `--numbered`.
4. List the generated filenames in `series` in apply order and record each
   file's SHA256 in `profile.json`. Pin the exact source export, target kernel
   build inputs and compiler. A changed patch byte, including a changed mail
   header, requires a new SHA256.
5. Run the base's `tools/pvm-oot/prepare.py` against the exact target kernel
   build. It checks regular-file mail format, SHA256, source fingerprints and
   ordered `git apply --check` before exporting prepared code. Then build with
   `PVM_OOT_MODE=1`, run modpost, package and install. Store runtime gate
   results in ignored per-run artifacts, not in tracked target manifests.

Keep the format check in both base repositories' `tools/pvm-oot/prepare.py`.
This context document owns the cross-distribution rule; the target profiles
own their generated patches and exact compatibility evidence.
