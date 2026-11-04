#!/bin/sh
# fs.sh — H22 test group FS (docs/design/x86-64-check.md §4.3) on the scratch disk (scripts/x86-test.sh fs IMAGE
# --scratch IMG: a fresh 2 GB BFS volume "scratch"): bfsmeta (metadata-heavy writes), a copy of /boot/system's
# apps and lib with MD5s compared before and after an unmount + mount, fragwrite (a 30 MB file in ~7500 holes),
# then checkfs -c and bfsbits (block bitmap against the superblock). Serial lines "X86T fs ...".
G=fs
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }

t bfsmeta 900 'bfsmeta: 4000 files' ./bfsmeta /scratch/meta 4000

# copy + MD5, again after a remount
md5tree() { (cd "$1" && find apps lib -type f | sort | xargs md5sum) > "$2" 2> /dev/null; }
mkdir -p /scratch/copy
start=$(date +%s)
cp -a /boot/system/apps /boot/system/lib /scratch/copy/
rc=$?
md5tree /boot/system /tmp/src.md5
md5tree /scratch/copy /tmp/dst.md5
n=$(wc -l < /tmp/src.md5)
size=$(du -s -k /scratch/copy | awk '{print $1}')
if [ $rc = 0 ] && [ "$n" -gt 100 ] && cmp -s /tmp/src.md5 /tmp/dst.md5; then
	say "result copy PASS rc=$rc $n files, $size KiB in $(( $(date +%s) - start )) s, MD5s equal"
else
	say "result copy FAIL rc=$rc $n files; $(diff /tmp/src.md5 /tmp/dst.md5 | head -n 3 | tr '\n' ' ')"
fi
sync
cd /
unmount /scratch
urc=$?
mount_scratch
cd $X86T_DIR
md5tree /scratch/copy /tmp/dst2.md5
if [ $urc = 0 ] && [ -n "$scratch_dev" ] && cmp -s /tmp/src.md5 /tmp/dst2.md5; then
	say "result remount PASS rc=0 MD5s equal after unmount + mount"
else
	say "result remount FAIL rc=$urc $(diff /tmp/src.md5 /tmp/dst2.md5 | head -n 3 | tr '\n' ' ')"
fi
rm -rf /scratch/copy

t fragwrite 1800 'FRAG ok' sh ./fragwrite.sh /scratch/frag
sync
check_volume() {	# TEST: checkfs -c /scratch and bfsbits of its device
	checkfs -c /scratch > /tmp/cf.txt 2>&1
	rc=$?
	while IFS= read -r l; do say "out $1: $l"; done < /tmp/cf.txt
	zeros=$(grep -a -c -E '^[[:space:]]0 blocks (not allocated|already set)' /tmp/cf.txt)
	freed=$(grep -a -o -E '[0-9]+ blocks could be freed' /tmp/cf.txt)
	errs=$(grep -a -c -E 'could not be opened|has wrong type|names don.t match|invalid b\+tree' /tmp/cf.txt)
	if [ $rc = 0 ] && [ "$zeros" = 2 ] && [ "$errs" = 0 ]; then
		say "result $1 PASS rc=$rc ($freed)"
	else
		say "result $1 FAIL rc=$rc zero counts $zeros of 2 (not allocated, already set), $freed, $errs node errors"
	fi
	t "$2" 120 '\(S - U = 0\)' ./bfsbits "$scratch_dev"
}
check_volume checkfs bfsbits
finish
