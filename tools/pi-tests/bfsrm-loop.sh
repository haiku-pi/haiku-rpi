#!/bin/sh
# bfsrm-loop.sh [ROUNDS [FILES]] — the BFS `rm -rf` hang probe without the first boot, for a bench session
# (scripts/pi-ssh.sh; docs/design/bfs-rmrf-hang.md "Pi check"): on a fresh BFS volume on the USB disk (never the SD
# card) ROUNDS times: bfsmeta FILES files (default 4000), then `rm -rf` of them in the background while this script
# runs `sync` in a loop beside it (what the first boot's PostInstallScript does once). A round whose rm is not done after
# 60 s is a hang: "BL HANG round N team T", then the kernel debugger is entered (kdl; the host types its commands).
# Needs ./bfsmeta and ./kdl in the current directory. Lines "BL ...".
rounds=${1:-20}
files=${2:-4000}
dev=$(ls /dev/disk/usb/*/0/raw 2> /dev/null | head -n 1)
case "$dev" in
/dev/disk/usb/*/0/raw) ;;
*) echo "BL no USB disk"; exit 1 ;;
esac
df | grep -a -q -F "$dev" && { echo "BL $dev is mounted"; exit 1; }
mkfs -t bfs -q "$dev" scratch > /dev/null 2>&1
mkdir -p /scratch
mount -t bfs "$dev" /scratch || { echo "BL mount failed"; exit 1; }
echo "BL start $dev rounds=$rounds files=$files $(date +%T)"
i=1
hung=0
while [ "$i" -le "$rounds" ]; do
	./bfsmeta /scratch/m$i "$files" > /dev/null 2>&1
	start=$(date +%s)
	rm -rf /scratch/m$i &
	rmpid=$!
	syncs=0
	while kill -0 $rmpid 2> /dev/null && [ $(($(date +%s) - start)) -lt 60 ]; do
		sync
		syncs=$((syncs + 1))
	done
	if kill -0 $rmpid 2> /dev/null; then
		echo "BL HANG round $i team $rmpid after $syncs syncs"
		hung=1
		./kdl "bfsrm hang team $rmpid"
		break
	fi
	wait $rmpid
	echo "BL round $i: rm $(($(date +%s) - start)) s, $syncs syncs"
	i=$((i + 1))
done
[ $hung = 0 ] && { echo "BL PASS $rounds rounds"; sync; unmount /scratch; }
