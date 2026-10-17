#!/usr/bin/env bash
# restore-peer-sd.sh — put the other project's release card image back on the Pi's SD card
# (agreed 2026-10-17: we may use the card, and restore it before they need an SD-boot test).
# Image + hash given by that project; the flash lane verifies the read-back SHA-256.
set -euo pipefail
img="${PEER_SD_IMAGE:-/home/houp/phoenix-rpi/artifacts/release-20261014/rpi4b-sd-2part.img}"
want="278fa51df8a6a894abb2c144fb8ca7a8d8d7eb5d5511b79c3c9f16345bb48607"
got="$(sha256sum "$img" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "restore-peer-sd: $img hash changed ($got)" >&2; exit 1; }
exec "$(dirname "$0")/sd-cycle.sh" --flash "$img" --no-boot --label peer-restore "$@"
