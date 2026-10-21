#!/usr/bin/env bash
# pi-session.sh — keep the Pi up for a while and work on it over ssh, instead of one boot per test: for
# anything that is not the kernel or the boot (Wine, Box64, programs, packages), copy new files over and
# run again in seconds (scripts/pi-ssh.sh).
#
#   scripts/pi-session.sh start [--minutes N] [--image IMG] [--keep-disk] [--add FILE:PATH]... [--label L]
#   scripts/pi-session.sh wait | status | stop
#
# start: a network boot (scripts/netboot-cycle.sh, in the background) of IMG (default the regular image) with
# tools/pi-tests/session.sh as its bootscript, the openssh package (installed by it) and the session's public key
# on the disk;
# returns once ssh answers. The cycle holds the bench lock (shared with the other project) for the whole
# session, so a session ends by itself after N minutes (default 480); `stop` ends it earlier (the Pi is
# powered off and the other project's netboot server restored). The serial log is the cycle's
# (artifacts/uart/<ts>-session-<label>.log); HDMI frames every 5 minutes.
# The key: artifacts/pi-session/id_ed25519, made on the first start (never in git).
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
dir="$HAIKU_RPI_ROOT/artifacts/pi-session"
key="$dir/id_ed25519"
state="$dir/state"
mkdir -p "$dir"

usage() { sed -n '6,8p' "$0" >&2; exit 2; }
session_pid() { [ -f "$state" ] && . "$state" && kill -0 "${pid:-0}" 2>/dev/null && echo "$pid"; }

# wait_up: until the running session's Pi answers ssh (its address: the one session.sh reports on the serial line)
wait_up() {
	local t ulog ip
	. "$state"
	for ((t = 0; t < 4500; t += 5)); do
		kill -0 "$pid" 2>/dev/null || { tail -n 5 "$dir/cycle.out" >&2; echo "pi-session: the cycle ended" >&2; exit 1; }
		ulog=$(ls -t "$HAIKU_RPI_ROOT"/artifacts/uart/*-"$label".log 2>/dev/null | head -n 1) || true
		ip=$([ -n "$ulog" ] && grep -a -o 'PIS sshd: exit 0, inet addr: [0-9.]*' "$ulog" | tail -n 1 | awk '{ print $NF }') || true
		if [ -n "$ip" ] && ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "user@$ip" true 2>/dev/null; then
			grep -q "^ip=" "$state" || echo "ip=$ip" >> "$state"
			echo "pi-session: up at $ip after $t s (scripts/pi-ssh.sh CMD; scripts/pi-session.sh stop)"
			return 0
		fi
		sleep 5
	done
	echo "pi-session: no ssh after $t s" >&2
	exit 1
}

case "${1:-}" in
start)
	shift
	minutes=480 img="$HAIKU_RPI_ROOT/artifacts/images/haiku-pi4-regular.img" label=session keep=() adds=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--minutes) minutes=$2; shift 2 ;;
		--image) img=$(realpath "$2"); shift 2 ;;
		--keep-disk) keep=(--keep-disk); shift ;;
		--add) adds+=(--add "$2"); shift 2 ;;
		--label) label=session-$2; shift 2 ;;
		*) usage ;;
		esac
	done
	[ -z "$(session_pid)" ] || { echo "pi-session: a session is running (pid $(session_pid)); stop it first" >&2; exit 1; }
	[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C haiku-pi-session -f "$key"
	ssh_pkg=$(ls "$HAIKU_RPI_ROOT"/artifacts/packages/openssh-[0-9]*-arm64.hpkg | tail -n 1)
	log="$dir/cycle.out"
	setsid nohup "$HAIKU_RPI_ROOT/scripts/netboot-cycle.sh" --image "$img" "${keep[@]}" --retry-wedge \
		--bootscript "$HAIKU_RPI_ROOT/tools/pi-tests/session.sh" --add "$key.pub:/boot/home/session.pub" \
		--add "$ssh_pkg:/boot/home/openssh.hpkg" "${adds[@]}" \
		--secs $((minutes * 60)) --label "$label" --hdmi-every 300 > "$log" 2>&1 < /dev/null &
	printf 'pid=%s\nlabel=%s\n' "$!" "$label" > "$state"
	echo "pi-session: starting (cycle pid $!, $minutes min, log $log)"
	wait_up
	;;
wait) [ -n "$(session_pid)" ] || { echo "pi-session: none" >&2; exit 1; }; wait_up ;;
status)
	p=$(session_pid) || true
	[ -n "$p" ] && { . "$state"; echo "pi-session: running (cycle pid $p${ip:+, ip $ip})"; } || echo "pi-session: none"
	;;
stop)
	p=$(session_pid) || true
	[ -n "$p" ] || { echo "pi-session: none"; exit 0; }
	kill -TERM "$p"
	while kill -0 "$p" 2>/dev/null; do sleep 1; done
	rm -f "$state"
	tail -n 3 "$dir/cycle.out"
	;;
*) usage ;;
esac
