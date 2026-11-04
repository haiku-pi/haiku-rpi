#!/usr/bin/env bash
# x86-test.sh — one H22 test-group run under KVM (docs/design/x86-64-check.md §4.3): boots IMAGE with
# scripts/qemu-x86.sh, the group's bootscript tools/x86-tests/GROUP.sh as UserBootscript, the cross-built
# tests (scripts/build-x86-tests.sh, default artifacts/x86-tests) and tools/x86-tests/lib.sh in /boot/home/x86t,
# debug_server set to kill crashed teams (no crash alert to hold a run), then grades the serial log with
# scripts/x86-grade.sh and appends the rows to artifacts/qemu-x86/results.tsv.
#
#   scripts/x86-test.sh GROUP IMAGE [--tests DIR] [--secs N] [--file FILE:PATH]... [qemu-x86.sh options...]
#
# IMAGE: rpi4 (sources/haiku-x86), up (sources/haiku-x86-up, hrev60314), kd1 (sources/haiku-x86-up-kd1,
# hrev60314 at KDEBUG_LEVEL 1) or a path. The config column is taken from --fw/--disk/--smp/--mem/--nic
# (defaults uefi, ahci, 4, 4G, virtio). The run ends at the guest's power-off (the bootscripts end with
# `shutdown -q`) or after --secs (default 1800). Exit status: x86-grade.sh's.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
group="$1" image="$2"; shift 2
case "$image" in
rpi4) img="$root/sources/haiku-x86/generated.x86_64/haiku-nightly-anyboot.iso" ;;
up) img="$root/sources/haiku-x86-up/generated.x86_64/haiku-nightly-anyboot.iso" ;;
kd1) img="$root/sources/haiku-x86-up-kd1/generated.x86_64/haiku-nightly-anyboot.iso" ;;
*) img="$image"; image="$(basename "$image")" ;;
esac
script="$root/tools/x86-tests/$group.sh"
[ -f "$script" ] || { echo "x86-test: no $script" >&2; exit 2; }
tests="$root/artifacts/x86-tests" secs=1800 files=() qargs=()
fw=uefi disk=ahci smp=4 mem=4G nic=virtio extra=""
while [ $# -gt 0 ]; do
	case "$1" in
	--tests) tests="$(realpath "$2")"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--file) files+=("$2"); shift 2 ;;
	--fw) fw="$2"; qargs+=("$1" "$2"); shift 2 ;;
	--disk) disk="$2"; qargs+=("$1" "$2"); shift 2 ;;
	--smp) smp="$2"; qargs+=("$1" "$2"); shift 2 ;;
	--mem) mem="$2"; qargs+=("$1" "$2"); shift 2 ;;
	--nic) nic="$2"; qargs+=("$1" "$2"); shift 2 ;;
	--machine|--topo) extra="$extra,${1#--}=$2"; qargs+=("$1" "$2"); shift 2 ;;
	--legacy-virtio) extra="$extra,legacy-virtio"; qargs+=("$1"); shift ;;
	*) qargs+=("$1"); shift ;;
	esac
done
[ -d "$tests" ] || { echo "x86-test: no tests in $tests (scripts/build-x86-tests.sh)" >&2; exit 2; }
config="$fw-$disk-smp$smp-$mem-$nic$extra"
label="$group-$image-$fw-$disk"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/x86-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf 'default_action kill\n' > "$tmp/debug_server"
adds=(--add "$root/tools/x86-tests/lib.sh:/boot/home/x86t/lib.sh"
	--add "$root/tools/pi-tests/kill-race-loop.sh:/boot/home/x86t/kill-race-loop.sh"
	--add "$root/tools/pi-tests/fragwrite.sh:/boot/home/x86t/fragwrite.sh"
	--add "$tmp/debug_server:/boot/home/config/settings/system/debug_server/settings")
while IFS= read -r f; do
	adds+=(--add "$f:/boot/home/x86t/${f#"$tests"/}")
done < <(find "$tests" -type f ! -name '*.sh' | sort)
for f in "${files[@]+"${files[@]}"}"; do adds+=(--add "$f"); done

"$root/scripts/qemu-x86.sh" --image "$img" --desktop --bootscript "$script" "${adds[@]}" --secs "$secs" \
	--shot-every 60 --label "$label" "${qargs[@]+"${qargs[@]}"}" 2>&1 | tee "$tmp/run.out" \
	| grep -v -E '^qemu-x86: (image-add|qemu-system)' || true
log=$(sed -n 's/.*serial [0-9]* lines: \(.*\.log\)$/\1/p' "$tmp/run.out" | tail -n 1)
[ -n "$log" ] || { echo "x86-test: no serial log" >&2; exit 1; }
po=no
grep -q 'guest powered off' "$tmp/run.out" && po=yes
"$root/scripts/x86-grade.sh" "$log" --image "$image" --config "$config" --poweroff "$po" \
	--tsv "$root/artifacts/qemu-x86/results.tsv"
