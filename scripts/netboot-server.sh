#!/usr/bin/env bash
# netboot-server.sh up IMG | dhcp | down | status — boot the Pi 4 from the network: Haiku's own network
# boot, with its boot volume on the host (a remote disk) instead of the SD card.
#
#   dhcp: only addresses for a Pi that boots from its SD card — DHCP with the host as gateway and DNS
#   server (the host masquerades 10.42.0.0/24), no TFTP, and no answer to the Pi firmware's network
#   boot requests (vendor class "PXEClient"), so the firmware still falls through to the card, also when
#   Haiku reboots.
#
#   - DHCP + TFTP (dnsmasq, on the Pi LAN only): the Pi's firmware loads start4.elf, the device tree,
#     config.txt and U-Boot from TFTP — the files of IMG's FAT partition, with the netboot U-Boot
#     (artifacts/uboot/u-boot-netboot.bin from scripts/build-uboot.sh). U-Boot takes an address by
#     DHCP, loads the Haiku loader by TFTP and starts it with "ip=<address>" in its load options.
#   - remote_disk_server (Haiku's tool, built for this host: scripts/build.sh remote_disk_server) serves
#     a copy of IMG (artifacts/netboot/disk.img): the loader finds it by broadcast, reads the kernel and
#     modules from its BFS partition, and the kernel mounts it as the boot volume over UDP
#     (drivers/disk/virtual/remote_disk), with the network modules preloaded.
#
# A fresh copy of IMG on every `up`: whatever Haiku writes stays out of the build output. The copy gets
# a resolv.conf with the DNS server DHCP offers (NETBOOT_DNS, default 1.1.1.1). Only one DHCP
# server may answer on the Pi LAN: `up` stops the peer project's netboot server; callers hold the bench
# lock (scripts/lib/bench.sh) and restore the peer afterwards (scripts/netboot-cycle.sh does both).
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
nb="$HAIKU_RPI_ROOT/artifacts/netboot"
st="$nb/state" tftp="$nb/tftp"
server="$HAIKU_RPI_ROOT/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/remote_disk_server/remote_disk_server"
uboot="$HAIKU_RPI_ROOT/artifacts/uboot/u-boot-netboot.bin"
bfs="$HAIKU_RPI_ROOT/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
dns="${NETBOOT_DNS:-1.1.1.1}"
mkdir -p "$st"

stop() {
	[ -f "$st/dnsmasq.pid" ] && sudo kill "$(cat "$st/dnsmasq.pid")" 2>/dev/null || true
	[ -f "$st/disk.pid" ] && kill "$(cat "$st/disk.pid")" 2>/dev/null || true
	rm -f "$st/dnsmasq.pid" "$st/disk.pid"
}

case "${1:-}" in
up)
	img="${2:?usage: $0 up IMG}"
	[ -f "$img" ] || { echo "netboot: no image $img" >&2; exit 1; }
	[ -x "$server" ] || { echo "netboot: no $server (scripts/build.sh remote_disk_server)" >&2; exit 1; }
	[ -f "$uboot" ] || { echo "netboot: no $uboot (scripts/build-uboot.sh)" >&2; exit 1; }
	stop
	peer_netboot_down

	# the boot files: the image's FAT partition, with the netboot U-Boot
	rm -rf "$tftp"; mkdir -p "$tftp"
	start=$(sfdisk -J "$img" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"])')
	mcopy -s -n -i "$img@@$((start * 512))" ::* "$tftp/"
	cp "$uboot" "$tftp/u-boot.bin"

	# NETBOOT_KEEP_DISK=1: boot the copy the last cycle left (what Haiku wrote stays, e.g. a Wine prefix),
	# if there is one; otherwise a fresh copy of IMG
	if [ "${NETBOOT_KEEP_DISK:-0}" = 1 ] && [ -f "$nb/disk.img" ]; then
		echo "netboot: keeping the last disk"
	else
		cp --reflink=auto "$img" "$nb/disk.img"
	fi
	# DNS: net_server leaves the boot interface alone (no DHCP, which would take its address away
	# for a moment), so the resolver gets its server here, in the copy only: the one DHCP offers
	p2=$(sfdisk -J "$img" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')
	printf 'nameserver %s\n' "$dns" > "$st/resolv.conf"
	printf 'mkdir -p /myfs/system/settings/network\ncp :%s /myfs/system/settings/network/resolv.conf\nsync\n' \
		"$st/resolv.conf" | "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" > "$st/bfs.log" 2>&1 || true
	echo "cat /myfs/system/settings/network/resolv.conf" | "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" 2>&1 \
		| grep -q "nameserver $dns" || { cat "$st/bfs.log" >&2; echo "netboot: resolv.conf not written" >&2; exit 1; }
	# NETBOOT_BOOTSCRIPT=FILE: installed as the disk's UserBootscript (as mkimage-pi4.sh --bootscript)
	if [ -n "${NETBOOT_BOOTSCRIPT:-}" ]; then
		printf 'mkdir -p /myfs/home/config/settings/boot\nrm /myfs/home/config/settings/boot/UserBootscript\ncp :%s /myfs/home/config/settings/boot/UserBootscript\nsync\n' \
			"$NETBOOT_BOOTSCRIPT" | "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" > "$st/bfs-boot.log" 2>&1 || true
		echo "cat /myfs/home/config/settings/boot/UserBootscript" | "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" 2>&1 \
			| grep -q -F "$(head -n 1 "$NETBOOT_BOOTSCRIPT")" \
			|| { cat "$st/bfs-boot.log" >&2; echo "netboot: bootscript not written" >&2; exit 1; }
	fi
	# NETBOOT_ADD="FILE:PATH ...": each FILE copied onto the disk as PATH (/boot/... of the booted system)
	for a in ${NETBOOT_ADD:-}; do
		src="${a%%:*}" dest="/myfs${a#*:/boot}"
		printf 'mkdir -p %s\nrm %s\ncp :%s %s\nsync\n' "$(dirname "$dest")" "$dest" "$src" "$dest" \
			| "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" > "$st/bfs-add.log" 2>&1 || true
		echo "ls -l $dest" | "$bfs" --start-offset $((p2 * 512)) "$nb/disk.img" 2>&1 | grep -q "$(stat -c %s "$src")" \
			|| { cat "$st/bfs-add.log" >&2; echo "netboot: $src not copied to ${a#*:}" >&2; exit 1; }
	done

	cat > "$st/dnsmasq.conf" <<CONF
# generated by netboot-server.sh
interface=$PI_LAN_IFACE
bind-interfaces
listen-address=$PI_LAN_HOST
port=0
dhcp-range=10.42.0.10,10.42.0.20,12h
dhcp-option=3,$PI_LAN_HOST
dhcp-option=6,$dns
dhcp-option=66,$PI_LAN_HOST
log-dhcp
enable-tftp
tftp-root=$tftp
tftp-no-blocksize
log-facility=$st/dnsmasq.log
pid-file=$st/dnsmasq.pid
dhcp-leasefile=$st/dnsmasq.leases
user=$(id -un)
group=$(id -gn)
CONF
	: > "$st/dnsmasq.log"
	sudo dnsmasq -C "$st/dnsmasq.conf"
	setsid nohup stdbuf -oL "$server" "$nb/disk.img" > "$st/disk.log" 2>&1 < /dev/null 9>&- &
	echo $! > "$st/disk.pid"
	sleep 1
	kill -0 "$(cat "$st/disk.pid")" || { echo "netboot: remote_disk_server died: $(tail -3 "$st/disk.log")" >&2; exit 1; }
	echo "netboot: up (dnsmasq pid $(cat "$st/dnsmasq.pid"), remote disk $(basename "$img"), TFTP $tftp)"
	;;
dhcp)
	stop
	cat > "$st/dnsmasq.conf" <<CONF
# generated by netboot-server.sh dhcp
interface=$PI_LAN_IFACE
bind-interfaces
listen-address=$PI_LAN_HOST
port=0
dhcp-range=10.42.0.10,10.42.0.20,12h
dhcp-option=3,$PI_LAN_HOST
dhcp-option=6,$dns
dhcp-vendorclass=set:firmware,PXEClient
dhcp-ignore=tag:firmware
log-dhcp
log-facility=$st/dnsmasq.log
pid-file=$st/dnsmasq.pid
dhcp-leasefile=$st/dnsmasq.leases
user=$(id -un)
group=$(id -gn)
CONF
	: > "$st/dnsmasq.log"
	sudo dnsmasq -C "$st/dnsmasq.conf"
	echo "netboot: DHCP only (dnsmasq pid $(cat "$st/dnsmasq.pid"); the Pi's firmware is not answered)"
	;;
down) stop; echo "netboot: down" ;;
status)
	for p in dnsmasq disk; do
		if [ -f "$st/$p.pid" ] && kill -0 "$(cat "$st/$p.pid")" 2>/dev/null; then echo "$p: up"; else echo "$p: down"; fi
	done ;;
*) echo "usage: $0 up IMG | dhcp | down | status" >&2; exit 2 ;;
esac
