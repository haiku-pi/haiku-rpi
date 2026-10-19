# Haiku arm64 packages (haiku-pi)

A [pkgman](https://www.haiku-os.org/guides/daily-tasks/install-applications) repository of arm64
packages for Haiku, built by the [haiku-pi](https://github.com/haiku-pi/haiku-rpi) port of Haiku to the
Raspberry Pi 4: Mesa (V3D OpenGL/GLES), SDL2, ffmpeg, HaikuWebKit, NetSurf, OpenSSL 3, curl and the
libraries they need. Haiku has no official arm64 HaikuPorts repository yet; these packages fill the gap
for this port. They are cross-built from the
[HaikuPorts](https://github.com/haikuports/haikuports) recipes (pinned commit, with our patches where
needed) — unofficial, not endorsed by the Haiku project.

## Use

```sh
pkgman add-repo https://haiku-pi.github.io/packages/arm64
pkgman refresh
pkgman install <package>
```

The haiku-pi images are configured with it as their `HaikuPorts` repository (`pkgman refresh` works out
of the box); on other arm64 Haiku installations, add it as above.

## Sources

Every package names its upstream and license in its package info (`package list -i <file>`). The
corresponding sources: the upstream releases the HaikuPorts recipes name, the recipes and patches of the
pinned HaikuPorts commit, and the build scripts and patches in
[haiku-pi/haiku-rpi](https://github.com/haiku-pi/haiku-rpi) (`scripts/build-packages.sh` and the scripts it
runs, `patches/`) and our forks ([mesa](https://github.com/haiku-pi/mesa),
[libdrm](https://github.com/haiku-pi/libdrm), [libglvnd](https://github.com/haiku-pi/libglvnd), branch
`rpi4`). Open an issue in haiku-pi/haiku-rpi to ask for a source archive of any package.

## Layout

`arm64/repo.info`, `arm64/repo` (the index), `arm64/repo.sha256`, `arm64/packages/*.hpkg`.
