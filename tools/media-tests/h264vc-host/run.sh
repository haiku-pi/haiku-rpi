#!/bin/bash
# run.sh CLIP.mp4 (H264VC_WORK=build.sh's directory): the h264_vc scenarios of videocore-services.md §1.3 against h264 alone
cd "${H264VC_WORK:?the build directory of build.sh}"
C=$1
THREADS=1 t/vctest $C ref > ref.txt 2>ref.err
run() { name=$1; shift; env "$@" t/vctest $C vc ${SEEK:-} > $name.txt 2>$name.err; rc=$?
  echo "== $name rc=$rc: $(tail -1 $name.err)"; grep -E "h264" $name.err | grep -v opened | head -3
  python3 - $name.txt <<'P'
import sys
ref={}
for l in open('ref.txt'):
    p=l.split(); ref[p[0]]=p
seq=[l.split() for l in open(sys.argv[1]) if l.strip()!='SEEK']
bad=[x for x in seq if x[0] not in ref or ref[x[0]][5]!=x[5]]
meta=[x for x in seq if x[0] in ref and (ref[x[0]][2:4]!=x[2:4])]
pts=[int(x[0]) for x in seq]
seg=[]; cur=[]
for x in pts:
    if cur and x<cur[-1]: seg.append(cur); cur=[]
    cur.append(x)
seg.append(cur)
print(f"   frames {len(seq)}, md5 mismatches {len(bad)}, duration/key mismatches {len(meta)}, segments {[ (s[0],len(s)) for s in seg]}, dup {len(pts)-len(set(pts))}")
if meta[:2]: print('   e.g.', meta[:2], ref[meta[0][0]])
P
}
run ok
run openfail FAKE_OPEN_FAIL=1
run fail5 FAKE_FAIL_AT=5
run fail12 FAKE_FAIL_AT=12
run fail100 FAKE_FAIL_AT=100
run env0 FFMPEG_H264_MMAL=0
SEEK=50 run seek50
SEEK=50 run seek50fail120 FAKE_FAIL_AT=120
SEEK=50 run seek50fail55 FAKE_FAIL_AT=55
