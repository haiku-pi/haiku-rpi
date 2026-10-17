#!/usr/bin/env bash
# qemu-raspi.sh — boot the Pi SD image on QEMU's raspi4b model: U-Boot (as the Pi firmware would
# start it) → haiku_loader.efi → kernel. Good for the boot chain and early kernel; QEMU's raspi4b
# has no PCIe, GENET, thermal or RNG200, and its "firmware" is only a DTB.
#
#   scripts/qemu-raspi.sh [--image IMG] [--secs N] [--gdb (wait for gdb) | --gdbserver] [--uart1] [--stock-dtb]
#
# The DTB gets stdout-path = the PL011 (uart0), like the real Pi with dtoverlay=disable-bt; --uart1 keeps
# the stock serial1 (mini UART). QEMU wires its SD card to the legacy SDHCI at 0x7e300000 (the real Pi's
# WiFi SDIO), not to emmc2, so that node is made to look like emmc2 (and the real emmc2 node unmatched),
# which lets Haiku's emmc2 driver boot from the card; --stock-dtb leaves the DTB alone. UART logs: artifacts/qemu/<ts>-raspi-uart{0,1}.log;
# a QMP socket at artifacts/qemu/raspi-qmp.sock (scripts/qmp-hmp.py, qmp-screendump.py); a final screenshot.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4.img"
secs=60 gdb=() uart1=0 stock=0
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$2"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--gdb) gdb=(-s -S); shift ;;
	--gdbserver) gdb=(-s); shift ;;	# attach any time: gdb-multiarch -ex "target remote :1234"
	--uart1) uart1=1; shift ;;
	--stock-dtb) stock=1; shift ;;
	*) echo "qemu-raspi: unknown option $1" >&2; exit 2 ;;
	esac
done
out="$root/artifacts/qemu"; mkdir -p "$out"
ts="$(date +%Y%m%d-%H%M%S)"
disk="$out/raspi-disk.img"
cp "$img" "$disk"
qemu-img resize -q -f raw "$disk" 512M	# raspi's SD model needs a power-of-two size
dtb="$out/raspi.dtb"
cp "$root/artifacts/pi-firmware/bcm2711-rpi-4-b.dtb" "$dtb"
[ "$uart1" = 1 ] || fdtput -t s "$dtb" /chosen stdout-path "/soc/serial@7e201000:115200n8"
if [ "$stock" = 0 ]; then
	fdtput -t s "$dtb" /emmc2bus/mmc@7e340000 compatible "haiku-rpi,unused-emmc2"
	fdtput -t s "$dtb" /soc/mmcnr@7e300000 compatible "brcm,bcm2711-emmc2"
fi
rm -f "$out/raspi-qmp.sock"
# A screenshot of the display just before the end (artifacts/qemu/<ts>-raspi.png).
( sleep "$((secs - 3))"; "$root/scripts/qmp-screendump.py" "$out/raspi-qmp.sock" "$out/$ts-raspi.png" ) 2>/dev/null &
timeout --foreground "$secs" qemu-system-aarch64 -M raspi4b -kernel "$root/sources/u-boot/u-boot.bin" \
	-dtb "$dtb" -drive "file=$disk,if=sd,format=raw" \
	-serial "file:$out/$ts-raspi-uart0.log" -serial "file:$out/$ts-raspi-uart1.log" \
	-display none -monitor none -qmp "unix:$out/raspi-qmp.sock,server,nowait" "${gdb[@]}" \
	< /dev/null > "$out/$ts-raspi-qemu.log" 2>&1 || true
wait
[ -f "$out/$ts-raspi.png" ] && echo "qemu-raspi: screenshot $out/$ts-raspi.png"
for u in 0 1; do
	tr -d '\r\000' < "$out/$ts-raspi-uart$u.log" > "$out/$ts-raspi-uart$u.txt"
	echo "qemu-raspi: uart$u $(wc -l < "$out/$ts-raspi-uart$u.txt") lines -> $out/$ts-raspi-uart$u.txt"
done
