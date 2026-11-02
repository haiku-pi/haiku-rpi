# Claude Code instructions

Boot sequence, in order, before any change:

1. [AGENTS.md](AGENTS.md) — rules, repos, the shared bench
2. The newest `docs/log/WEEK-*.md` — current plan, progress and blockers
3. [docs/PLAN.md](docs/PLAN.md) — milestones (skim; read the active one)

Read `docs/knowledge/` only for the area you are touching.

- Use the scripts in `scripts/` for builds and Pi cycles; extend them rather than inlining pipelines.
- Pi cycles: one at a time, always via `scripts/sd-cycle.sh` (it holds the shared bench lock and
  restores the bench default on exit).
- Commit in `sources/haiku` on branch `rpi4`, push to `origin` (the haiku-pi fork); then record the
  state with `scripts/snapshot-state.sh` and commit + push this repo.
- Heavy builds go through `scripts/heavy-build.sh` (one at a time, memory-capped).
- Releases: follow [docs/RELEASING.md](docs/RELEASING.md); a release is not done until README, KNOWN-ISSUES,
  HAIKU-RPI4-CHANGES and the other user-facing docs describe it (`scripts/release-docs-check.sh TAG` prints `ok`).
