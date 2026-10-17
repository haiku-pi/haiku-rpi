# Pi 4 EEPROM netboot prep

This is a **one-time** SD-card flash that reconfigures the Pi 4's
on-board EEPROM bootloader to enable network boot. After it succeeds,
every subsequent power-on tries SD → USB → Network in order.

The regular SD-card boot workflow (build → flash → run) is **unchanged**;
this only adds netboot as a fallback when no SD card is present.

## Generate the prep image

```
./scripts/prepare-pi-eeprom-netboot.sh
```

Output:

- `artifacts/eeprom-netboot/eeprom-prep-sd.img` — flashable SD image
- `artifacts/eeprom-netboot/eeprom-prep-sd.img.meta.txt` — sha256 + config

The script clones (or refreshes) `raspberrypi/rpi-eeprom` on the Lima VM,
picks the latest stable Pi 4 EEPROM blob, embeds the config below, signs
it (sha256 over `pieeprom.upd`), and wraps the three required files
(`recovery.bin`, `pieeprom.upd`, `pieeprom.sig`) into a 32 MiB FAT32
single-partition SD image.

Default config embedded into the EEPROM:

```
BOOT_ORDER=0xf241   SD → USB → Network → restart
TFTP_PREFIX=2       no per-serial subdir; files at TFTP root
BOOT_UART=1         early bootloader UART log
NET_INSTALL_AT_POWER_ON=0
ENABLE_SELF_UPDATE=0
```

Override via env: `PI_EEPROM_BOOT_ORDER`, `PI_EEPROM_TFTP_PREFIX`,
`PI_EEPROM_BOOT_UART`.

## Flash and run

1. Insert a microSD card (any size ≥ 64 MB; will be wiped).
2. Flash with the same command/path you use for the normal Phoenix SD
   image — see `scripts/print-rpi4b-macos-flash-commands.sh`. Substitute
   the source path with `artifacts/eeprom-netboot/eeprom-prep-sd.img`.
3. Eject the SD, insert into the Pi 4, **leave the network unplugged**
   for this step (we don't want it to attempt netboot before the EEPROM
   is updated).
4. `./scripts/pi_power_on.sh`
5. Watch the green ACT LED.
   - **Fast steady blink** (~10 Hz) for ~10 seconds → success. EEPROM
     updated.
   - **Four slow flashes repeating** → SD couldn't be read; check the
     flash.
   - **Other patterns** → see
     [Pi 4 LED warning flashes](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#led-warning-flash-codes).
6. `./scripts/pi_power_off.sh`
7. **Remove the prep SD card.**

## Verify

To confirm the EEPROM took the new config, you can do either of:

- Re-flash a Phoenix-RTOS SD image and capture UART. The Pi will boot
  Phoenix as before — the SD path still has highest priority.
- Or, with no SD inserted, power on with a USB-UART cable attached and
  net unplugged. With `BOOT_UART=1`, you should see the bootloader print
  its config (including `BOOT_ORDER=0xf241`) over UART before failing
  netboot due to no DHCP reply.

## Next step

Once the EEPROM is confirmed, the next milestone is the host-side
DHCP/TFTP server on `en7` and the automated test-cycle script. See the
plan in the session log; this doc covers prep only.
