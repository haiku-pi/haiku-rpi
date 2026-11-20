#!/bin/sh
# blender-b7.sh — blender -7 (docs/design/blender.md §7.14): OpenImageDenoise (Cycles' Denoise, the
# compositor's Denoise node) and the `aud` module (NumPy). Run over ssh in a Pi session with the desktop
# running (aud plays through SDL audio):
#
#   sh blender-b7.sh DIR [LABEL]
#
# DIR/packages: blender -7, oidn, numpy_python3.10 and what they need (pkgman installs the ones the image does
# not have in that very version, as blender-m3.sh); blender-m5-scene.py next to this script. Blender is the
# installed package (BLENDER=PATH for another). Output lines start with "BB7 "; grade by the PASS lines. Logs:
# /tmp/bb7-LABEL-NAME.txt; PNGs: /boot/home/bb7-LABEL/.
#   oidn-bench   oidnBenchmark on its own (device, NEON, threads, time per 1920x1080 RT filter)
#   cycles-oidn  _cycles.with_openimagedenoise is True
#   noisy/denoised  blender-m5-scene.py with Cycles, 960x540, 16 samples, without and with denoising
#   factory      the factory scene exactly as it is (1920x1080, denoising on in the file), time and memory
#   compositor   a Denoise node in the compositor
#   aud          import aud; Sound.data() as a NumPy array, Sound.buffer() from one, played on Blender's
#                sound device (a GUI Blender; aud-b: the same headless)
#   extras       Alembic export/import, the Ocean modifier, a Mantaflow smoke bake (blender-b7-extras.py)
dir=$1 label=${2:-run}
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
here=$(dirname "$0")
[ -d "$dir/packages" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
out=/boot/home/bb7-$label
mkdir -p "$out"
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true
dbg0=$(grep -c 'debug_server: Thread' /var/log/syslog)

new=""
for f in "$dir"/packages/*.hpkg; do
	[ -e "/boot/system/packages/$(basename "$f")" ] || new="$new $f"
done
if [ -n "$new" ]; then
	pkgman install -y $new > /tmp/bb7-$label-pkgman.txt 2>&1
	echo "BB7 $label pkgman: status $?, $(echo $new | wc -w) packages"
else
	echo "BB7 $label pkgman: all installed"
fi
[ -x "$bl" ] || { echo "BB7 $label blender: FAIL no $bl"; exit 1; }
echo "BB7 $label packages: $(ls /boot/system/packages | grep -E '^(blender|oidn|numpy_python3.10)-' | tr '\n' ' ')"

used() { sysinfo -mem | sed -n 's/.*used\/max *\([0-9]*\) .*/\1/p'; }
# run NAME COMMAND...: the command's output in /tmp/bb7-LABEL-NAME.txt, its wall time and the peak of the
# system's used memory above the value before it (sampled every second)
run() {
	name=$1
	shift
	idle=$(used)
	rm -f /tmp/bb7-$label-done
	( peak=$idle; while [ ! -f /tmp/bb7-$label-done ]; do u=$(used); [ "$u" -gt "$peak" ] && peak=$u; \
		echo $peak > /tmp/bb7-$label-peak; sleep 1; done ) &
	start=$(date +%s)
	"$@" > /tmp/bb7-$label-$name.txt 2>&1
	status=$?
	wall=$(( $(date +%s) - start ))
	touch /tmp/bb7-$label-done
	sleep 2
	mem=$(( ($(cat /tmp/bb7-$label-peak) - idle) / 1048576 ))
	echo "BB7 $label $name: status $status, $wall s wall, peak $mem MB above $(( idle / 1048576 )) MB"
	return $status
}
# rendered NAME: PASS with Blender's own render time when the PNG was saved
rendered() {
	t=$(sed -n 's/.*Time: \([0-9:.]*\).*/\1/p' /tmp/bb7-$label-$1.txt | tail -n 1)
	if grep -q "Saved: .*$1_0001.png" /tmp/bb7-$label-$1.txt && [ -s "$out/$1_0001.png" ]; then
		echo "BB7 $label $1: PASS render $t"
	else
		echo "BB7 $label $1: FAIL"
		grep -v '^Fra:' /tmp/bb7-$label-$1.txt | tail -n 20
	fi
	grep -i -E 'denois|oidn|error' /tmp/bb7-$label-$1.txt | grep -v '^Fra:' | sort | uniq -c | head -n 5
}

# 1. OIDN alone: the device module loads (dlopen from the core library's directory), NEON, threads
run oidn-bench oidnBenchmark -v 2 -s 1920 1080 -r 'RT\.hdr_alb_nrm\..*' -n 2
grep -E 'Device|Arch|Threads|Affinity|Tile|msec|error|Error' /tmp/bb7-$label-oidn-bench.txt | head -n 12
grep -q 'msec' /tmp/bb7-$label-oidn-bench.txt && echo "BB7 $label oidn-bench: PASS" || echo "BB7 $label oidn-bench: FAIL"

# 2. Cycles sees the denoiser
run cycles-oidn "$bl" -b --factory-startup --python-expr \
	"import _cycles; print('BB7OIDN', _cycles.with_openimagedenoise)"
grep -q '^BB7OIDN True' /tmp/bb7-$label-cycles-oidn.txt && echo "BB7 $label cycles-oidn: PASS" \
	|| { echo "BB7 $label cycles-oidn: FAIL"; tail -n 10 /tmp/bb7-$label-cycles-oidn.txt; }

# 3. a lit scene with glossy, metal and glass at 16 samples: without, then with OpenImageDenoise (the
# default: albedo + normal, accurate prefilter)
cyc="import bpy; s = bpy.context.scene; s.cycles.samples = 16; s.cycles.use_adaptive_sampling = False; s.cycles.device = 'CPU'"
run noisy "$bl" -b --factory-startup --python "$here/blender-m5-scene.py" -E CYCLES -t 4 \
	--python-expr "$cyc; s.cycles.use_denoising = False" -o "$out/noisy_####" -F PNG -f 1
rendered noisy
run denoised "$bl" -b --factory-startup --python "$here/blender-m5-scene.py" -E CYCLES -t 4 \
	--python-expr "$cyc; s.cycles.use_denoising = True; s.cycles.denoiser = 'OPENIMAGEDENOISE'" \
	-o "$out/denoised_####" -F PNG -f 1
rendered denoised

# 4. the factory scene as it is (blender -6 rendered it without denoising: 1 min 37 s, 251 MB)
run factory "$bl" -b --factory-startup -t 4 -E CYCLES -o "$out/factory_####" -F PNG -f 1
rendered factory

# 5. the compositor's Denoise node (Render Layers -> Denoise -> Composite) on the default cube
comp="import bpy; s = bpy.context.scene; s.render.resolution_x = 480; s.render.resolution_y = 270; s.cycles.samples = 8; s.cycles.use_denoising = False; s.use_nodes = True; t = s.node_tree; rl = t.nodes['Render Layers']; c = t.nodes['Composite']; d = t.nodes.new('CompositorNodeDenoise'); t.links.new(rl.outputs['Image'], d.inputs['Image']); t.links.new(d.outputs['Image'], c.inputs['Image']); print('BB7COMP node', d.bl_idname)"
run compositor "$bl" -b --factory-startup -t 4 -E CYCLES --python-expr "$comp" -o "$out/compositor_####" -F PNG -f 1
rendered compositor

# 6. aud (audaspace's Python API, built with NumPy): a 440 Hz sine as a NumPy array, a sound made from
# that array, played for 0.6 s on Blender's own sound device (aud.Device(): SDL, Preferences > System >
# Sound): the handle's position must advance. aud.Device('SDL') would fail: Blender holds the one SDL audio
# device a team can open on Haiku (blender.md §7.14)
audpy="
import os, time, numpy, aud
s = aud.Sound.sine(440, 48000).limit(0, 1.0)
d = s.data()
print('BB7AUD data', type(d).__name__, d.shape, d.dtype, round(float(abs(d).max()), 3), flush=True)
b = aud.Sound.buffer(numpy.ascontiguousarray(d), 48000)
print('BB7AUD buffer', b.specs, b.length, flush=True)
print('BB7AUD numpy', numpy.__version__, numpy.__file__, flush=True)
try:
    dev = aud.Device()
    print('BB7AUD device', dev.rate, dev.channels, flush=True)
    h = dev.play(b)
    time.sleep(0.6)
    print('BB7AUD position', round(h.position, 2), h.status, flush=True)
    h.stop()
except Exception as e:
    print('BB7AUD device error', e, flush=True)
os._exit(0)
"
run aud "$bl" --factory-startup -p 0 0 640 480 --python-expr "$audpy"
grep '^BB7AUD' /tmp/bb7-$label-aud.txt
if grep -q "^BB7AUD data ndarray (48000, 1) float32" /tmp/bb7-$label-aud.txt \
	&& grep -q '^BB7AUD position 0\.[3-9]' /tmp/bb7-$label-aud.txt; then
	echo "BB7 $label aud: PASS"
else
	echo "BB7 $label aud: FAIL"
	grep -v '^BB7AUD' /tmp/bb7-$label-aud.txt | tail -n 15
fi
# the same without a window (-b)
run aud-b "$bl" -b --factory-startup --python-expr "$audpy"
grep '^BB7AUD' /tmp/bb7-$label-aud-b.txt | sed 's/^/(-b) /'

# 7. Alembic, the Ocean modifier (FFTW) and Mantaflow smoke (blender-b7-extras.py)
run extras "$bl" -b --factory-startup -t 4 --python "$here/blender-b7-extras.py" -- "$out/extras"
grep '^BB7X' /tmp/bb7-$label-extras.txt | sed "s/^BB7X /BB7 $label extras /"

echo "BB7 $label debugger: $(( $(grep -c 'debug_server: Thread' /var/log/syslog) - dbg0 )) new entries"
echo "BB7 $label done"
