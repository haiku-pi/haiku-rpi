# haiku-rpi

Coordination repository for porting [Haiku](https://www.haiku-os.org) to the Raspberry Pi 4:
build and test scripts, bench tools, documentation and integration manifests.

The Haiku sources live in the fork [haiku-pi/haiku](https://github.com/haiku-pi/haiku), branch `rpi4`;
`scripts/bootstrap.sh` clones it and the other sources into `sources/`.

![Haiku on a Raspberry Pi 4: WebPositive, GLTeapot on the V3D, ActivityMonitor, About Haiku, a Terminal with the hardware, Quake II](docs/screenshots/02-desktop-quake2.png)

*Haiku on a Raspberry Pi 4 Model B, from its SD card (HDMI capture, unedited) — more in
[docs/screenshots/](docs/screenshots/).*

- **Try it: [docs/TRY-IT.md](docs/TRY-IT.md)** — what works, how to build the image and flash an SD card
- **Packages:** `pkgman` works out of the box with our arm64 repository,
  [haiku-pi/packages](https://github.com/haiku-pi/packages)

- Plan and milestones: [docs/PLAN.md](docs/PLAN.md)
- Current progress: [docs/log/](docs/log/)
- Rules for working here: [AGENTS.md](AGENTS.md)
