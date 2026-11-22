# blender-bw.py — the viewport's frame time per configuration, in time windows a bus monitor running next to
# Blender (tools/haiku-tests/axibw, started by blender-bw.sh) can be matched against (docs/design/blender.md
# §7.17). Started windowed:
#
#   blender FILE.blend -p 0 0 W H --python blender-bw.py -- HOLD CONFIG...
#
# Per config: a warm-up, then HOLD seconds of interactive orbiting (per frame a 2° view_orbit + the 3D view's
# region drawn and swapped, as blender-perf.py's "orbit"), then HOLD seconds of idle (nothing drawn: the
# baseline of the same window). With BBW_NAV=1 (blender-bw.sh NAV=1) the orbit is a real middle-button drag
# instead (Blender then knows it is navigating, and Workbench takes its navigation path).
# Lines (t = time.monotonic(), CLOCK_MONOTONIC as axibw prints):
#   "BBW orbit <config> <t0> <t1> <frames> <ms/frame> <viewport WxH>"
#   "BBW idle <config> <t0> <t1>"
# configs: solid (factory Workbench), aa-off (the scene's viewport AA off: Workbench's F12 render setting),
# vaa-off / vaa-fxaa / vaa-5 (Preferences ▸ Viewport ▸ Anti-Aliasing: off, FXAA, 5 samples),
# smooth-off (Preferences ▸ Viewport ▸ Smooth Wires off),
# overlays-off, grid-off (floor + axes), outline-off (selected object's outline), matprev (Material Preview,
# EEVEE; warmed up until its shaders are compiled), and "+"-combinations of the switches.
import os
import sys
import time

import bpy

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
HOLD = float(ARGS[0]) if ARGS else 10.0
CONFIGS = ARGS[1:] or ["solid"]
NAV = os.environ.get("BBW_NAV") == "1"


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
    if not hasattr(configure, "default_vaa"):
        configure.default_vaa = bpy.context.preferences.system.viewport_aa
        say("defaults: scene viewport_aa", configure.default_aa, "preferences viewport_aa", configure.default_vaa)
    # ("aa-off" is the scene's setting, used by Workbench's F12 render; "vaa-off" the viewport's, Preferences ▸
    # Viewport ▸ Quality ▸ Anti-Aliasing)
    display.viewport_aa = 'OFF' if "+aa-off" in "+" + config else configure.default_aa
    vaa = configure.default_vaa
    for word in config.split("+"):
        if word.startswith("vaa-"):
            vaa = word[4:].upper()   # vaa-off, vaa-fxaa, vaa-5, vaa-8, ...
    bpy.context.preferences.system.viewport_aa = vaa
    overlay = space.overlay
    overlay.show_overlays = "overlays-off" not in config
    bpy.context.preferences.system.use_overlay_smooth_wire = "smooth-off" not in config
    # single overlays: the grid (floor + axes), the selected object's outline
    grid = "grid-off" not in config
    overlay.show_floor = overlay.show_axis_x = overlay.show_axis_y = grid
    overlay.show_outline_selected = "outline-off" not in config
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
    # (the configs change preferences: not saved at quit, so the next run starts from the same ones)
    bpy.context.preferences.use_preferences_save = False
    yield 3.0
    for config in CONFIGS:
        configure(config)
        yield 0.5
        warm_up(config)
        win, area, region = view3d()
        if NAV:
            # real navigation: blender-bw.sh drags with the middle button (uiinject) for HOLD s once it sees
            # "navready"; the frames are the viewport's draws in the drag's steady part
            draws = []
            handle = bpy.types.SpaceView3D.draw_handler_add(lambda: draws.append(time.monotonic()), (),
                                                            'WINDOW', 'POST_PIXEL')
            yield 0.1
            ready = time.monotonic()
            say("navready", config, "%.3f" % ready)
            yield HOLD + 4.0
            bpy.types.SpaceView3D.draw_handler_remove(handle, 'WINDOW')
            steady = [t for t in draws if ready + 1.5 <= t <= ready + HOLD - 0.5]
            if len(steady) < 3:
                say("ERROR", config, "only %d draws while dragging" % len(steady))
                continue
            t0, t1, frames = steady[0], steady[-1], len(steady) - 1
        else:
            t0 = time.monotonic()
            frames = 0
            while time.monotonic() - t0 < HOLD:
                orbit_frame(win, area, region)
                frames += 1
            t1 = time.monotonic()
        say("orbit", config, "%.3f %.3f %d %.1f %dx%d" % (t0, t1, frames, 1000 * (t1 - t0) / frames,
                                                          region.width, region.height))
        # (a timer's next call is counted from the start of the call that returned the interval, here
        # before the orbit loop: a short step first, so the idle window really lasts HOLD seconds)
        yield 0.1
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
