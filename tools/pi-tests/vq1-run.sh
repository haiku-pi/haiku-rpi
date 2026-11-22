#!/usr/bin/env bash
# vq1-run.sh IMAGE MODE TOTAL CHUNK LABEL [CLIP] — host side of VQ1 (vq1-mpswitch.sh; MODE enc: vq1-ffenc.sh;
# MODE vchiqcut: vq1-vchiqcut.sh, needs artifacts/vq1/bin/vchiq_test_cut from scripts/build-vchiq-test.sh):
# TOTAL MediaPlayer H.264 decodes (or ffmpeg transcodes) back to back on IMAGE in network sessions (scripts/pi-session.sh --label vq1), CHUNK per ssh call. A
# PANIC leaves the Pi in the kernel debugger: the session is stopped, its serial log kept, and the next chunk starts
# a new one. CLIP: a file of artifacts/media-tests/h264 (default play-1080p30-aac.mp4: MediaPlayer's usual
# configuration, the VideoCore decoder by rate). PLAY/GAP pass through to the Pi. URL=PREFIX: the players open
# PREFIX/CLIP instead of the file (the BUrl reader, as in MP3's runs that panicked; serve artifacts/media-tests/h264
# with wp4-httpd.py, e.g. URL=http://10.42.0.1:8096/f; MP3's clip, artifacts/wp3/clips, is the one that triggers it).
# Lines "VQ1RUN <label> ...": per chunk the players started, PANIC or not, the kernel's VQ1 lines (the diagnostic
# kernels: "cut_area ... unmaps wired pages above it" without the fix, "unmap ... waits for wired pages above it"
# with it); at the end the totals. KEEP=1: leave the session running at the end (for the next run on it).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
img=$(realpath "${1:?usage: vq1-run.sh IMAGE MODE TOTAL CHUNK LABEL [CLIP]}")
mode=${2:?}; total=${3:?}; chunk=${4:?}; label=${5:?}
clip=${6:-play-1080p30-aac.mp4}
export PI_SESSION_LABEL=vq1
say() { echo "VQ1RUN $label $*"; }
done_=0 panics=0 cuts=0 waits=0 sessions=0
up=no
# a vq1 session already running (started by an earlier run, the same image) is used
if grep -q "^label=session-vq1$" "$root/artifacts/pi-session/state" 2> /dev/null \
		&& "$root/scripts/pi-session.sh" status | grep -q running; then
	up=yes
	ulog=$(ls -t "$root"/artifacts/uart/*-session-vq1.log | head -n 1)
	"$root/scripts/pi-ssh.sh" put "$root"/tools/pi-tests/vq1-{mpswitch,ffenc,vchiqcut}.sh \
		"$root/artifacts/vq1/bin/vchiq_test_cut" /boot/home/vq1/
	say "using the running session (serial log $ulog; the scripts copied again)"
fi
while [ "$done_" -lt "$total" ]; do
	if [ $up = no ]; then
		clipAdd=()
		[ ! -f "$root/artifacts/media-tests/h264/$clip" ] \
			|| clipAdd=(--add "$root/artifacts/media-tests/h264/$clip:/boot/home/vq1/$clip")
		"$root/scripts/pi-session.sh" start --image "$img" --label vq1 --minutes 90 "${clipAdd[@]}" \
			--add "$root/tools/pi-tests/vq1-mpswitch.sh:/boot/home/vq1/vq1-mpswitch.sh" \
			--add "$root/tools/pi-tests/vq1-ffenc.sh:/boot/home/vq1/vq1-ffenc.sh" \
			--add "$root/tools/pi-tests/vq1-vchiqcut.sh:/boot/home/vq1/vq1-vchiqcut.sh" \
			--add "$root/artifacts/vq1/bin/vchiq_test_cut:/boot/home/vq1/vchiq_test_cut" > /dev/null
		sessions=$((sessions + 1))
		ulog=$(ls -t "$root"/artifacts/uart/*-session-vq1.log | head -n 1)
		up=yes
		say "session $sessions up (serial log $ulog)"
	fi
	n=$((total - done_ < chunk ? total - done_ : chunk))
	start=$(wc -l < "$ulog")
	src=/boot/home/vq1/$clip
	[ -z "${URL:-}" ] || src=$URL/$clip
	case "$clip" in testsrc2*) src=$clip ;; esac	# enc: ffmpeg's test pattern
	if [ "$mode" = vchiqcut ]; then
		cmd="KILL=${KILL:-} ARGS='${ARGS:-1024 400}' VQ1_CUT_US=${VQ1_CUT_US:-2000} sh /boot/home/vq1/vq1-vchiqcut.sh $n $label"
	elif [ "$mode" = enc ]; then
		cmd="sh /boot/home/vq1/vq1-ffenc.sh $n $src $label"
	else
		cmd="PLAY=${PLAY:-4} GAP=${GAP:-1} sh /boot/home/vq1/vq1-mpswitch.sh $n $mode $src $label"
	fi
	timeout $((n * 20 + 120)) "$root/scripts/pi-ssh.sh" "$cmd" | grep -a "^VQ1 $label result" || true
	sleep 3
	new=$(tail -n +"$((start + 1))" "$ulog" | tr -d '\r')
	started=$(grep -a -c "VQ1 $label [0-9]*/$n started" <<< "$new" || true)
	c=$(grep -a -c "VQ1: cut_area" <<< "$new" || true)
	w=$(grep -a -c "VQ1: unmap" <<< "$new" || true)
	grep -a "VQ1: \|PANIC" <<< "$new" | sed "s/^/VQ1RUN $label   /" || true
	cuts=$((cuts + c)) waits=$((waits + w))
	if grep -a -q "PANIC" <<< "$new"; then
		panics=$((panics + 1))
		say "chunk: PANIC in player $started of $n"
		grep -a -A 14 "PANIC" <<< "$new" | grep -a -E "PANIC|Thread|<kernel_arm64>|vchiq" | sed "s/^/VQ1RUN $label   /" || true
		done_=$((done_ + started))
		"$root/scripts/pi-session.sh" stop > /dev/null || true
		up=no
	else
		say "chunk: $started of $n players, no PANIC"
		done_=$((done_ + started))
		[ "$started" -gt 0 ] || { say "no player started: stopping"; break; }
	fi
done
[ $up = no ] || [ -n "${KEEP:-}" ] || "$root/scripts/pi-session.sh" stop > /dev/null || true
say "total: $done_ players ($mode, ${URL:+$URL/}$clip), $panics PANIC, $cuts wired-tail cuts, $waits wired-tail waits, $sessions sessions"
