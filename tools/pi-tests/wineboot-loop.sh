#!/bin/sh
# wineboot-loop.sh N — the mega image's first-boot Wine setup, N times: a fresh prefix (wineboot -i), then
# wait up to 120 s for the wineserver to end with all its processes (wineserver -w). A Wine process that
# never ends (seen once in the 10-29 smoke runs) shows as "WBL i: HANG", with the processes left
# (killed afterwards). Lines "WBL ..." on stdout; ends "WBL end N runs, H hangs".
n=${1:-10}
hangs=0
i=1
while [ $i -le $n ]; do
	wineserver -k > /dev/null 2>&1
	sleep 2
	rm -rf /boot/home/.wine
	start=$(date +%s)
	wineboot -i > /tmp/wbl-$i.log 2>&1 < /dev/null
	rc=$?
	wineserver -w > /dev/null 2>&1 &
	w=$!
	t=0
	while [ $t -lt 120 ] && kill -0 $w 2> /dev/null; do sleep 1; t=$((t + 1)); done
	if kill -0 $w 2> /dev/null; then
		hangs=$((hangs + 1))
		echo "WBL $i: HANG (wineboot exit $rc after $(( $(date +%s) - start - t )) s;" \
			"left: $(ps | grep 'lib/wine/aarch64-unix/wine' | grep -v grep | awk '{ print $2 }' | tr '\n' ' '))"
		wineserver -k > /dev/null 2>&1
		sleep 3
		kill -9 $w 2> /dev/null
	else
		echo "WBL $i: ok, wineboot exit $rc, all ended after $(( $(date +%s) - start )) s"
	fi
	i=$((i + 1))
done
echo "WBL end $n runs, $hangs hangs"
