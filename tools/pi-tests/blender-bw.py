# blender-bw.py — the viewport's frame time per configuration, in time windows a bus monitor running next to
# Blender (tools/haiku-tests/axibw, started by blender-bw.sh) can be matched against (docs/design/blender.md
# §7.17). Started windowed:
#
#   blender FILE.blend -p 0 0 W H --python blender-bw.py -- HOLD CONFIG...
#
# Per config: a warm-up, then HOLD seconds of interactive orbiting (per frame a 2° view_orbit + the 3D view's
# region drawn and swapped, as blender-perf.py's "orbit"), then HOLD seconds of idle (nothing drawn: the
# baseline of the same window). Lines (t = time.monotonic(), CLOCK_MONOTONIC as axibw prints):
#   "BBW orbit <config> <t0> <t1> <frames> <ms/frame> <viewport WxH>"
#   "BBW idle <config> <t0> <t1>"
# configs: solid (factory Workbench), aa-off (scene viewport AA off), smooth-off (Preferences ▸ Viewport ▸
# Smooth Wires off), overlays-off, aa-off+smooth-off, matprev (Material Preview, EEVEE; warmed up until its
# shaders are compiled), and "+"-combinations of the switches.
import sys
import time

import bpy

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
HOLD = float(ARGS[0]) if ARGS else 10.0
CONFIGS = ARGS[1:] or ["solid"]


def say(*args):
    print("BBW", *args, flush=True)


def view3d():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                for region in area.regions:
                    if region.type == 'WINDOW':
                        return win, area, region
    return None, None, None


def orbit_frame(win, area, region):
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.view3d.view_orbit(angle=0.035, type='ORBITRIGHT')
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.wm.redraw_timer(type='DRAW_SWAP', iterations=1)


def configure(config):
    _, area, _ = view3d()
    space = area.spaces.active
    display = bpy.context.scene.display
    if not hasattr(configure, "default_aa"):
        configure.default_aa = display.viewport_aa
    display.viewport_aa = 'OFF' if "aa-off" in config else configure.default_aa
    space.overlay.show_overlays = "overlays-off" not in config
    bpy.context.preferences.system.use_overlay_smooth_wire = "smooth-off" not in config
    space.shading.type = 'MATERIAL' if "matprev" in config else 'SOLID'


def warm_up(config):
    win, area, region = view3d()
    # Material Preview compiles EEVEE's shaders in the background first: orbit until two successive
    # 10-frame batches take about as long (at most 120 s)
    limit = 120.0 if "matprev" in config else 3.0
    start = time.monotonic()
    last = None
    while time.monotonic() - start < limit:
        t0 = time.monotonic()
        for i in range(10):
            orbit_frame(win, area, region)
        t = time.monotonic() - t0
        if "matprev" not in config:
            continue
        if last is not None and abs(t - last) < 0.1 * last and time.monotonic() - start > 20:
            break
        last = t
    say("warm", config, "%.1f s" % (time.monotonic() - start))


def steps():
    say("start", bpy.app.version_string, "hold", HOLD)
    yield 3.0
    for config in CONFIGS:
        configure(config)
        yield 0.5
        warm_up(config)
        win, area, region = view3d()
        t0 = time.monotonic()
        frames = 0
        while time.monotonic() - t0 < HOLD:
            orbit_frame(win, area, region)
            frames += 1
        t1 = time.monotonic()
        say("orbit", config, "%.3f %.3f %d %.1f %dx%d" % (t0, t1, frames, 1000 * (t1 - t0) / frames,
                                                          region.width, region.height))
        t0 = time.monotonic()
        yield HOLD
        say("idle", config, "%.3f %.3f" % (t0, time.monotonic()))
    say("end")
    bpy.ops.wm.quit_blender()


gen = steps()


def tick():
    try:
        return next(gen)
    except StopIteration:
        return None
    except Exception as e:
        say("ERROR", repr(e))
        bpy.ops.wm.quit_blender()
        return None


bpy.app.timers.register(tick, first_interval=5.0)
