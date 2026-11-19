# blender-perf.py — where Blender's viewport frame time goes on the Pi (docs/design/blender.md §7): frame rates of
# the solid (Workbench) viewport in several configurations, one "BPF <scene> <config> <what> <fps> fps
# (<ms> ms/frame)" line each. Started windowed:
#
#   blender FILE.blend -p 0 0 1600 900 --python blender-perf.py [-- quick]
#
# what: "window"  = wm.redraw_timer DRAW_WIN_SWAP (every region of the window drawn, then swapped)
#       "orbit"   = per frame a 2° view_orbit (tags the 3D viewport) + DRAW_SWAP (that region drawn + swapped):
#                   what interactive navigation costs
# configs: default; aa-off (the scene's viewport anti-aliasing, scene.display.viewport_aa, OFF); overlays-off;
#          smooth-off (Preferences ▸ Viewport ▸ Smooth Wires off); and combinations ("aa-off+smooth-off")
# scenes:  cube (the factory scene), 100k (+ a 320x160 UV sphere, ~102k triangles)
# "quick" after "--": only the cube scene's default config, 120 orbit frames (for a profiled run).
import sys
import time

import bpy

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QUICK = "quick" in ARGS
# other words after "--": the configs to measure (default: all of the list below)
CONFIGS = [a for a in ARGS if a != "quick"]
FRAMES = 120 if QUICK else 40


def say(*args):
    print("BPF", *args, flush=True)


def view3d():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                for region in area.regions:
                    if region.type == 'WINDOW':
                        return win, area, region
    return None, None, None


def measure(scene_name, config):
    win, area, region = view3d()
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=3)
        if not QUICK:
            start = time.perf_counter()
            bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=FRAMES)
            t = (time.perf_counter() - start) / FRAMES
            say(scene_name, config, "window", "%.1f fps (%.0f ms/frame)" % (1 / t, 1000 * t))
    # (each operator with a fresh override: after redraw_timer the 3D view's poll fails in the same one)
    start = time.perf_counter()
    for i in range(FRAMES):
        with bpy.context.temp_override(window=win, area=area, region=region):
            bpy.ops.view3d.view_orbit(angle=0.035, type='ORBITRIGHT')
        with bpy.context.temp_override(window=win, area=area, region=region):
            bpy.ops.wm.redraw_timer(type='DRAW_SWAP', iterations=1)
    t = (time.perf_counter() - start) / FRAMES
    say(scene_name, config, "orbit", "%.1f fps (%.0f ms/frame) viewport %dx%d" % (
        1 / t, 1000 * t, region.width, region.height))


def configure(config):
    _, area, _ = view3d()
    space = area.spaces.active
    display = bpy.context.scene.display
    if not hasattr(configure, "default_aa"):
        configure.default_aa = display.viewport_aa
        say("viewport_aa default", configure.default_aa)
    display.viewport_aa = 'OFF' if "aa-off" in config else configure.default_aa
    space.overlay.show_overlays = "overlays-off" not in config
    # (Preferences > Viewport > Quality: "Smooth Wires" for overlays, an extra anti-aliasing pass)
    bpy.context.preferences.system.use_overlay_smooth_wire = "smooth-off" not in config


def steps():
    say("start", bpy.app.version_string)
    yield 3.0
    configs = CONFIGS or (["default"] if QUICK else
                          ["default", "aa-off", "overlays-off", "aa-off+overlays-off", "smooth-off",
                           "aa-off+smooth-off"])
    for scene_name in (["cube"] if QUICK else ["cube", "100k"]):
        if scene_name == "100k":
            win, area, region = view3d()
            with bpy.context.temp_override(window=win, area=area, region=region):
                bpy.ops.mesh.primitive_uv_sphere_add(segments=320, ring_count=160, location=(3, 0, 0))
            yield 1.0
        for config in configs:
            configure(config)
            yield 0.5
            measure(scene_name, config)
            yield 0.2
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
