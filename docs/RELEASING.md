# Cutting a release image

**Audience:** whoever publishes the next `image-YYYY-MM-DD` (the main session, or a person). **Rule (owner
2026-11-02): a release is not done until the user-facing docs describe it.** Every big change — a fix,
a feature, a new toolchain — reaches README, KNOWN-ISSUES, HAIKU-RPI4-CHANGES and the other pages below
in the same publish, not later. `scripts/release-docs-check.sh` enforces the mechanical part.

## Steps

1. **Build** the candidate from a clean state of the trees (`git status` clean in sources/haiku):
   `PI_IMAGE_OUT=$PWD/artifacts/images/haiku-pi4-DATE.img scripts/build.sh -sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=4500 @pi-mmc`
   (U-Boot from `scripts/build-uboot.sh`, patches/u-boot applied).
2. **Session checks:** `scripts/release-check.sh IMG LABEL` — must end `REL result: 0 problems`.
3. **The card path:** `scripts/sd-cycle.sh --flash IMG …` and a second warm boot (`--until 'kdebug>'`), the
   revision line checked, 0 `PANIC` lines.
4. **Archive:** `artifacts/release/<short>/`: `xz -T4 -9`, sha256 of `.img` and `.img.xz`, `SHA256SUMS`,
   `notes.md` (from the previous notes: "New since …" written for users — what changed, why it matters,
   how it was found/measured; "What is in it" with the haiku SHA and hrev; checksums).
5. **Docs, in the same change** (then `scripts/release-docs-check.sh TAG` must print `ok`):
   - **README.md** and **docs/TRY-IT.md** — the download link, file name and size; the main limits.
   - **docs/KNOWN-ISSUES.md** — rows fixed by this release leave the register (their story stays in the
     log); new known issues get a row; references to removed rows repointed; "Checked against the weekly
     logs up to" set to now.
   - **docs/HAIKU-RPI4-CHANGES.md** — every haiku `rpi4` commit of ours since the previous release, in its
     area's table (and the "Start here" table for defects that are not Pi-specific); the check lists the
     missing hashes.
   - **docs/HARDWARE-SUPPORT.md** — rows whose status or numbers changed (new hardware, new measurements).
   - **docs/USER-GUIDE.md** — new features users can use (how), troubleshooting rows changed by fixes.
   - **docs/HANDS-ON-CHECKS.md** — what the newest release is and what the card holds.
   - **docs/MEGA-IMAGE.md** — if the mega image's content changed.
   - **docs/PLAN.md** — backlog items done/changed; the weekly log's "Next".
   - **design/*.md** of the changed areas — status sections ("Pi results", "Decision").
   - Packages published with it (wine, numpy, dev tools, gcc_syslibs …): their design docs, and the
     release notes' "in the package repository" line.
6. **Publish:** `gh release create TAG -R haiku-pi/haiku-rpi --title … --notes-file notes.md IMG.xz SHA256SUMS`;
   packages that depend on this image (e.g. a new libroot symbol) with `scripts/publish-repo.sh` *after* it.
7. **Record:** `scripts/snapshot-state.sh release-TAG` (manifest), the weekly log entry (times from `date`),
   commit with explicit pathspecs, push.
8. **The card** back to what the owner expects (the mega image, docs/HANDS-ON-CHECKS.md), if a step flashed it.

## Toolchain note

From the switch to GCC 16.2 (design/gcc16.md "Decision"): image-2026-11-03 is the last 13.3 release. A 16.2
release publishes `gcc_syslibs` 16.2 to the repository with it (checked on a 13.3 image first), and its notes
say so; other packages are not republished just for the compiler.
