#!/bin/sh
# shadercache.sh — a UserBootscript for Mesa's on-disk shader cache: Photocraft's GPU probe (wgpu on V3DV;
# its compositor's pipelines) three times, the first with the cache empty, and the cache directory's
# size after each; then GLTeapot (OpenGL on the v3d driver) to its first window three times. Serial
# lines "SHC ...". Needs /boot/system/non-packaged/bin/photocraft-gpu-probe (scripts/build-photocraft.sh
# gpu), /boot/home/launchtime (tools/haiku-tests/launchtime.cpp) and a Mesa built with the shader cache.
out=/dev/dprintf
say() { echo "SHC $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
cache=/boot/home/config/cache/mesa_shader_cache
sleep 25
rm -rf $cache $cache"_db"
mkdir -p /tmp/shc-out
for run in 1 2 3; do
	t0=$(date +%s%N)
	timeout -s KILL 300 /boot/system/non-packaged/bin/photocraft-gpu-probe /tmp/shc-out > /tmp/shc.txt 2>&1
	say "probe $run: exit $? ms $(ms $t0) $(grep -o 'pipelines built in [0-9]* ms' /tmp/shc.txt)"
	say "cache after $run: $(du -sk /boot/home/config/cache/mesa_shader_cache* 2> /dev/null | tr '\n' ' ')"
done
for run in 1 2 3; do
	/boot/home/launchtime -q /boot/system/demos/GLTeapot 60 > /tmp/shc-gl.txt 2>&1 < /dev/null
	say "GLTeapot $run: $(grep -o 'window after [0-9]*' /tmp/shc-gl.txt) cache $(du -sk $cache 2> /dev/null | cut -f1) KiB"
	sleep 2
done
grep -a "case \|panic\|error\|Error" /tmp/shc.txt | head -20 | while read l; do say "$l"; done
tail -n 8 /tmp/shc.txt | while read l; do say "tail: $l"; done
say done
