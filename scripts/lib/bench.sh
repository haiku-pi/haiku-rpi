# bench.sh — shared settings for the Pi 4 bench scripts (sourced, not run).
#
# The bench (UART /dev/ttyUSB0, the Meross plug, the Pi LAN on the USB-C adapter) is shared
# with another project on this host. Every Pi power/UART cycle and every change to the Pi
# LAN's DHCP/TFTP server runs under the flock $PI_BENCH_LOCK; afterwards the other project's
# netboot server is restored ($PEER_NETBOOT_UP), because netboot is the bench's default lane.
HAIKU_RPI_ROOT="${HAIKU_RPI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PI_BENCH_LOCK="${PI_BENCH_LOCK:-/home/houp/.pi-bench.lock}"
PI_LAN_IFACE="${PI_LAN_IFACE:-enx00e04c680f3e}"
PI_LAN_HOST="${PI_LAN_HOST:-10.42.0.1}"
PI_UART="${PI_UART:-/dev/ttyUSB0}"
PI_PLUG="${PI_PLUG:-/home/houp/meross-plug/plug.py}"
HDMI_GRABBER="${HDMI_GRABBER:-/dev/video4}"
PEER_ROOT="${PEER_ROOT:-/home/houp/phoenix-rpi}"
PEER_NETBOOT_UP="${PEER_NETBOOT_UP:-$PEER_ROOT/scripts/netboot-server-up.sh}"
PEER_NETBOOT_DOWN="${PEER_NETBOOT_DOWN:-$PEER_ROOT/scripts/netboot-server-down.sh}"
FLASHLANE_PORT="${FLASHLANE_PORT:-8099}"
PYTHON="${PYTHON:-python3}"

# bench_lock: take the bench lock on fd 9 for the rest of the calling script.
bench_lock() {
	exec 9>"$PI_BENCH_LOCK"
	if ! flock -w "${PI_BENCH_LOCK_WAIT:-3600}" 9; then
		echo "bench: could not get $PI_BENCH_LOCK (another Pi cycle running?)" >&2
		exit 75
	fi
	if fuser "$PI_UART" >/dev/null 2>&1; then
		echo "bench: $PI_UART is held by: $(fuser "$PI_UART" 2>&1)" >&2
		exit 75
	fi
}

pi_power() {	# on|off — the Pi's smart plug (cloud; retried, since one call can time out)
	local i
	for i in 1 2 3; do
		"$PI_PLUG" "$1" >/dev/null 2>&1 && { echo "bench: power $1"; return 0; }
		sleep 3
	done
	echo "bench: power $1 FAILED" >&2
	return 1
}

# hdmi_snap <out.png>: one frame from the capture card (BT.709 limited range, 1080p).
hdmi_snap() {
	[ -e "$HDMI_GRABBER" ] || return 1
	timeout --foreground 5 ffmpeg -y -loglevel error -f v4l2 -input_format yuyv422 \
		-video_size 1920x1080 -i "$HDMI_GRABBER" -vf 'scale=in_color_matrix=bt709:in_range=tv' \
		-frames:v 1 "$1" </dev/null >/dev/null 2>&1 && return 0
	timeout --foreground 5 ffmpeg -y -loglevel error -f v4l2 -i "$HDMI_GRABBER" \
		-frames:v 1 "$1" </dev/null >/dev/null 2>&1
}

# peer_netboot_restore: bring the other project's netboot server back (the bench default).
peer_netboot_restore() {
	[ -x "$PEER_NETBOOT_UP" ] || return 0
	(cd "$PEER_ROOT" && "$PEER_NETBOOT_UP") >/dev/null 2>&1 \
		&& echo "bench: peer netboot server restored" \
		|| echo "bench: WARNING peer netboot server restore failed" >&2
}
