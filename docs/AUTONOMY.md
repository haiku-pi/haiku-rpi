# Autonomous operation

The port runs as a long-lived Claude Code session. Its scheduled jobs live only in that session,
so **re-create them after every restart**:

| Job | Cron (local time) | What |
|---|---|---|
| heartbeat | `13,43 * * * *` | if idle: read CLAUDE.md, the newest `docs/log/WEEK-*.md` "Next" list and `docs/PLAN.md`, continue the next step |
| upstream sync | `23 4 * * 6` | `scripts/upstream-sync.sh --merge`, validate (build, QEMU virt → Tracker, QEMU raspi4b), push `rpi4` |

Rules the jobs carry: Pi cycles only through `scripts/sd-cycle.sh` (shared bench lock), one at a
time; never force-push; commit Haiku changes on `rpi4` and push to the haiku-pi fork; keep the
weekly log current; tell the owner when a testable build (Desktop on HDMI from SD) exists.
